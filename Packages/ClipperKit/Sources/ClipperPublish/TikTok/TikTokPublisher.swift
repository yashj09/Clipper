import Foundation

/// How a file is split for TikTok's FILE_UPLOAD transfer.
///
/// Rules (https://developers.tiktok.com/doc/content-posting-api-media-transfer-guide, "Chunk restrictions"):
/// "The value of total_chunk_count should be equal to video_size divided by chunk_size, rounded down to the nearest
/// integer. Each chunk must be at least 5 MB but no greater than 64 MB, except for the final chunk, which can be greater
/// than chunk_size (up to 128 MB) to accommodate any trailing bytes. Videos with a total size less than 5 MB must be
/// uploaded as a whole … Videos with a total size greater than 64 MB must be uploaded in multiple chunks. There must be a
/// minimum of 1 chunk and a maximum of 1000 chunks. File chunks must be uploaded sequentially."
///
/// TikTok doesn't say whether "MB" is 10^6 or 2^20 bytes, so limits use the stricter reading of each side: chunks are
/// ≥ 5 MiB and ≤ 64,000,000 bytes, whole uploads only up to 64,000,000 bytes.
public struct TikTokChunkPlan: Sendable, Equatable {
    public static let minChunk: Int64 = 5 * 1024 * 1024
    public static let maxChunk: Int64 = 64_000_000
    public static let maxFinalChunk: Int64 = 128_000_000
    public static let maxChunkCount: Int64 = 1000
    /// Default chunk for multi-chunk uploads: 10,000,000 bytes, as in TikTok's own example.
    public static let preferredChunk: Int64 = 10_000_000

    public let videoSize: Int64
    public let chunkSize: Int64
    public let totalChunkCount: Int64

    public init(videoSize: Int64, preferredChunkSize: Int64 = TikTokChunkPlan.preferredChunk) throws {
        guard videoSize > 0 else { throw PublishError.invalidFile("the video is empty") }
        self.videoSize = videoSize
        if videoSize <= Self.maxChunk {
            chunkSize = videoSize
            totalChunkCount = 1
            return
        }
        let needed = (videoSize + Self.maxChunkCount - 1) / Self.maxChunkCount   // keep count ≤ 1000
        chunkSize = min(max(preferredChunkSize, needed, Self.minChunk), Self.maxChunk)
        totalChunkCount = videoSize / chunkSize                                     // rounded down
        guard totalChunkCount <= Self.maxChunkCount else {
            throw PublishError.invalidFile("the video is too large for TikTok (\(videoSize) bytes)")
        }
    }

    /// Byte range of chunk `index` (0-based); the last chunk absorbs the trailing bytes.
    public func range(ofChunk index: Int64) -> Range<Int64> {
        let start = index * chunkSize
        let end = index == totalChunkCount - 1 ? videoSize : start + chunkSize
        return start..<end
    }

    public var chunks: [Range<Int64>] { (0..<totalChunkCount).map(range(ofChunk:)) }
}

/// Sends a video to the creator's TikTok inbox as a draft (Content Posting API "Upload", scope `video.upload`); the user
/// finishes the post (caption, sound, privacy) in the TikTok app.
///
/// - Init: https://developers.tiktok.com/doc/content-posting-api-reference-upload-video —
///   `POST /v2/post/publish/inbox/video/init/`, `Content-Type: application/json; charset=UTF-8`, body
///   `{"source_info": {"source": "FILE_UPLOAD", "video_size", "chunk_size", "total_chunk_count"}}` → `data.publish_id`,
///   `data.upload_url` (valid one hour), `error.code` ("ok" on success), `error.message`, `error.log_id`. 6 requests/min.
/// - Transfer: PUT each chunk to `upload_url` with `Content-Type` video/mp4|video/quicktime|video/webm, `Content-Length`,
///   `Content-Range: bytes {FIRST}-{LAST}/{TOTAL}`; 206 = more expected, 201 = all received, 5xx = retry the chunk
///   (content-posting-api-media-transfer-guide).
/// - Status: https://developers.tiktok.com/doc/content-posting-api-reference-get-video-status —
///   `POST /v2/post/publish/status/fetch/` `{"publish_id"}` → `data.status` PROCESSING_UPLOAD | SEND_TO_USER_INBOX |
///   PUBLISH_COMPLETE | FAILED (+ `data.fail_reason`). 30 requests/min per token.
public struct TikTokPublisher: Publisher {
    public static let scopes = ["user.info.basic", "video.upload"]
    public static let defaultAPIBaseURL = URL(string: "https://open.tiktokapis.com")!

    public var platform: Platform { .tiktok }
    public let tokens: TokenManager
    public let apiBaseURL: URL
    public let retry: RetryPolicy
    public let preferredChunkSize: Int64
    /// Between status polls; ≥ 2 s keeps within 30 requests/min.
    public let pollInterval: Duration
    /// Give up polling (the upload still completes on TikTok's side) after this long.
    public let pollTimeout: Duration
    let http: HTTPClient

    public init(tokens: TokenManager, apiBaseURL: URL = TikTokPublisher.defaultAPIBaseURL, retry: RetryPolicy = .standard,
                preferredChunkSize: Int64 = TikTokChunkPlan.preferredChunk, pollInterval: Duration = .seconds(3),
                pollTimeout: Duration = .seconds(600), session: URLSession? = nil) {
        self.tokens = tokens; self.apiBaseURL = apiBaseURL; self.retry = retry
        self.preferredChunkSize = preferredChunkSize; self.pollInterval = pollInterval; self.pollTimeout = pollTimeout
        self.http = session.map(HTTPClient.init(session:)) ?? HTTPClient()
    }

    public func isConnected() async -> Bool { tokens.hasStoredToken() }

    public func publish(_ request: PublishRequest,
                        progress: (@Sendable (UploadProgress) -> Void)? = nil) async throws -> PublishResult {
        let reader = try FileChunkReader(url: request.file)
        let plan = try TikTokChunkPlan(videoSize: reader.size, preferredChunkSize: preferredChunkSize)
        progress?(UploadProgress(fraction: 0, message: "Starting TikTok upload…"))

        let (publishID, uploadURL) = try await initialize(plan)
        try await transfer(reader, plan: plan, to: uploadURL, contentType: videoContentType(for: request.file), progress: progress)
        progress?(UploadProgress(fraction: 0.95, message: "Waiting for TikTok to process the video…"))
        let state = try await waitForInbox(publishID)
        progress?(UploadProgress(fraction: 1, message: "Sent to TikTok"))

        let caption = ([request.title] + request.tags.map { "#" + $0.replacingOccurrences(of: " ", with: "") })
            .filter { !$0.isEmpty && $0 != "#" }.joined(separator: " ")
        var status: String
        switch state {
        case "PUBLISH_COMPLETE": status = "Posted from the TikTok inbox draft."
        case "SEND_TO_USER_INBOX": status = "Sent to your TikTok inbox as a draft. Open the TikTok app, tap the notification, and finish the post there"
            + (caption.isEmpty ? "." : " (suggested caption: \(caption)).")
        default: status = "Uploaded; TikTok is still processing it (\(state)). Check the TikTok app's inbox shortly."
        }
        if !request.attributions.isEmpty {
            status += " Add the music credits to the caption: " + request.attributions.joined(separator: "; ") + "."
        }
        status += " Unaudited TikTok apps are limited (sandbox/target users only, at most 5 pending drafts per 24 h,"
            + " private-only direct posts) until the app passes TikTok's audit."
        return PublishResult(platform: .tiktok, remoteID: publishID, url: nil, status: status)
    }

    // MARK: - Steps

    private func initialize(_ plan: TikTokChunkPlan) async throws -> (publishID: String, uploadURL: URL) {
        let body = try JSONSerialization.data(withJSONObject: ["source_info": [
            "source": "FILE_UPLOAD", "video_size": plan.videoSize, "chunk_size": plan.chunkSize,
            "total_chunk_count": plan.totalChunkCount,
        ]], options: [.sortedKeys])
        let data = try await postJSON("/v2/post/publish/inbox/video/init/", body: body)
        guard let payload = data["data"] as? [String: Any], let publishID = payload["publish_id"] as? String,
              let urlString = payload["upload_url"] as? String, let uploadURL = URL(string: urlString) else {
            throw PublishError.invalidResponse("TikTok init returned no publish_id/upload_url")
        }
        return (publishID, uploadURL)
    }

    private func transfer(_ reader: FileChunkReader, plan: TikTokChunkPlan, to uploadURL: URL, contentType: String,
                          progress: (@Sendable (UploadProgress) -> Void)?) async throws {
        for (index, range) in plan.chunks.enumerated() {
            try Task.checkCancellation()
            let chunk = try reader.read(range)
            let isLast = index == plan.chunks.count - 1
            // The upload_url carries its own credentials; no Authorization header (as in TikTok's curl example).
            let (data, response) = try await http.sendWithRetry(retry, body: chunk) {
                var request = URLRequest(url: uploadURL)
                request.httpMethod = "PUT"
                request.setValue(contentType == "application/octet-stream" ? "video/mp4" : contentType,
                                 forHTTPHeaderField: "Content-Type")
                request.setValue(String(chunk.count), forHTTPHeaderField: "Content-Length")
                request.setValue("bytes \(range.lowerBound)-\(range.upperBound - 1)/\(plan.videoSize)",
                                 forHTTPHeaderField: "Content-Range")
                return request
            }
            switch response.statusCode {
            case 201: guard isLast else { return }   // TikTok has everything already
            case 206 where !isLast: break
            case 200, 206: break
            case 403: throw PublishError.api(platform: .tiktok, code: "upload_url_expired",
                                             message: "the upload URL expired (uploads must finish within an hour)")
            case 404: throw PublishError.uploadSessionExpired
            case 416: throw PublishError.api(platform: .tiktok, code: "range_not_satisfiable",
                                             message: "TikTok rejected chunk \(index + 1) of \(plan.chunks.count): " + data.utf8Text)
            default: throw PublishError.http(status: response.statusCode, body: data.utf8Text)
            }
            progress?(UploadProgress(fraction: 0.95 * Double(range.upperBound) / Double(plan.videoSize),
                                     message: "Uploading to TikTok (chunk \(index + 1) of \(plan.chunks.count))"))
        }
    }

    /// Polls until the draft lands in the inbox (or is posted). Returns the last status; throws on FAILED.
    private func waitForInbox(_ publishID: String) async throws -> String {
        let body = try JSONSerialization.data(withJSONObject: ["publish_id": publishID])
        let deadline = ContinuousClock.now + pollTimeout
        var lastStatus = "PROCESSING_UPLOAD"
        while true {
            let json = try await postJSON("/v2/post/publish/status/fetch/", body: body)
            let payload = json["data"] as? [String: Any] ?? [:]
            lastStatus = payload["status"] as? String ?? lastStatus
            switch lastStatus {
            case "SEND_TO_USER_INBOX", "PUBLISH_COMPLETE":
                return lastStatus
            case "FAILED":
                throw PublishError.publishFailed(platform: .tiktok, reason: Self.describe(failReason: payload["fail_reason"] as? String))
            default:
                guard ContinuousClock.now + pollInterval < deadline else { return lastStatus }
                try await Task.sleep(for: pollInterval)
            }
        }
    }

    /// POST JSON to the Open API; unwraps the `error` envelope.
    private func postJSON(_ path: String, body: Data) async throws -> [String: Any] {
        let url = apiBaseURL.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/")
        let (data, response) = try await http.authorizedSend(tokens, platform: .tiktok, retry: retry, body: body) {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
            return request
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let error = json?["error"] as? [String: Any]
        let code = error?["code"] as? String
        if let code, code != "ok" {
            var message = (error?["message"] as? String) ?? ""
            if let logID = error?["log_id"] as? String ?? error?["logid"] as? String { message += " (log_id \(logID))" }
            if code == "spam_risk_too_many_pending_share" {
                message += " — TikTok allows at most 5 pending drafts per 24 hours; post or delete the pending ones in the app."
            }
            throw PublishError.api(platform: .tiktok, code: code, message: message)
        }
        guard (200..<300).contains(response.statusCode), let json else {
            throw PublishError.http(status: response.statusCode, body: data.utf8Text)
        }
        return json
    }

    static func describe(failReason: String?) -> String {
        switch failReason {
        case "file_format_check_failed": "unsupported video format"
        case "duration_check_failed": "the video's duration isn't allowed"
        case "frame_rate_check_failed": "unsupported frame rate"
        case "picture_size_check_failed": "unsupported resolution"
        case "spam_risk_too_many_posts": "too many posts via the API in 24 hours; post from the TikTok app"
        case "auth_removed": "the TikTok account revoked Clipper's access"
        case let reason?: reason
        case nil: "unknown reason"
        }
    }
}

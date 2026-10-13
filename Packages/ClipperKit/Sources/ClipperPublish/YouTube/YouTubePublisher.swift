import Foundation

/// Uploads to YouTube with the Data API v3 resumable protocol, then attaches caption sidecars.
///
/// - Resumable upload: https://developers.google.com/youtube/v3/guides/using_resumable_upload_protocol
///   POST …/upload/youtube/v3/videos?uploadType=resumable&part=snippet,status (JSON metadata, `X-Upload-Content-Length`,
///   `X-Upload-Content-Type`) → `Location` session URI; PUT chunks (multiples of 256 KiB) with
///   `Content-Range: bytes first-last/total`; "308 Resume Incomplete" + `Range: bytes=0-N` means N+1 bytes are stored;
///   after 500/502/503/504 back off and ask for the status with an empty PUT `Content-Range: bytes */total`; 404 means
///   the session expired.
/// - Captions: https://developers.google.com/youtube/v3/docs/captions/insert — POST …/upload/youtube/v3/captions
///   (multipart, `part=snippet`, snippet.videoId/language/name required), scope `youtube.force-ssl`, 400 quota units.
public struct YouTubePublisher: Publisher {
    public static let uploadScope = "https://www.googleapis.com/auth/youtube.upload"
    public static let captionsScope = "https://www.googleapis.com/auth/youtube.force-ssl"
    public static let scopes = [uploadScope, captionsScope]
    public static let defaultUploadBaseURL = URL(string: "https://www.googleapis.com/upload/youtube/v3")!
    /// Resumable chunks must be multiples of 256 KiB.
    public static let chunkQuantum = 256 << 10
    static let maxTitleLength = 100
    static let maxDescriptionBytes = 5000
    static let maxTagsLength = 500
    static let shortsSuffix = " #Shorts"

    public var platform: Platform { .youtube }
    public let tokens: TokenManager
    public let uploadBaseURL: URL
    public let chunkSize: Int
    public let retry: RetryPolicy
    /// "People & Blogs"; the API requires a category.
    public let categoryID: String
    let http: HTTPClient

    public init(tokens: TokenManager, uploadBaseURL: URL = YouTubePublisher.defaultUploadBaseURL,
                chunkSize: Int = 8 << 20, retry: RetryPolicy = .standard, categoryID: String = "22",
                session: URLSession? = nil) {
        self.tokens = tokens
        self.uploadBaseURL = uploadBaseURL
        let quanta = max(1, chunkSize / Self.chunkQuantum)
        self.chunkSize = quanta * Self.chunkQuantum
        self.retry = retry
        self.categoryID = categoryID
        self.http = session.map(HTTPClient.init(session:)) ?? HTTPClient()
    }

    public func isConnected() async -> Bool { tokens.hasStoredToken() }

    public func publish(_ request: PublishRequest,
                        progress: (@Sendable (UploadProgress) -> Void)? = nil) async throws -> PublishResult {
        let reader = try FileChunkReader(url: request.file)
        progress?(UploadProgress(fraction: 0, message: "Starting YouTube upload…"))
        let sessionURL = try await startSession(request, size: reader.size)
        let video = try await uploadChunks(reader, to: sessionURL, progress: progress)
        guard let videoID = video["id"] as? String, !videoID.isEmpty else {
            throw PublishError.invalidResponse("YouTube didn't return a video id")
        }

        var captionNotes: [String] = []
        for (index, caption) in request.captions.enumerated() {
            progress?(UploadProgress(fraction: 0.9 + 0.1 * Double(index) / Double(request.captions.count),
                                     message: "Uploading captions (\(caption.url.lastPathComponent))…"))
            do {
                let language = caption.language ?? Self.captionLanguage(for: caption.url, videoFile: request.file)
                try await uploadCaption(caption.url, language: language, videoID: videoID)
                captionNotes.append("captions \(language) added")
            } catch {
                // The video is already up; report caption failures instead of failing the publish.
                captionNotes.append("captions \(caption.url.lastPathComponent) failed: \(error.localizedDescription)")
            }
        }
        progress?(UploadProgress(fraction: 1, message: "Uploaded to YouTube"))

        let privacy = ((video["status"] as? [String: Any])?["privacyStatus"] as? String) ?? request.visibility.rawValue
        var status = "Uploaded as \(privacy)."
        if privacy != request.visibility.rawValue {
            status = "Uploaded, but YouTube set it to \(privacy) instead of \(request.visibility.rawValue)."
        }
        if !captionNotes.isEmpty { status += " " + captionNotes.joined(separator: "; ") + "." }
        if request.visibility != .private || privacy != request.visibility.rawValue {
            // Google's videos.insert docs (checked Oct 2026) say unverified projects are no longer restricted to private,
            // but projects that haven't passed the API compliance audit have historically been locked to private.
            status += " If YouTube keeps it private, your Google API project is unverified/unaudited: request YouTube's"
                + " API compliance audit, and change the visibility in YouTube Studio meanwhile."
        }
        let url = URL(string: request.isShort ? "https://youtube.com/shorts/\(videoID)" : "https://youtu.be/\(videoID)")
        return PublishResult(platform: .youtube, remoteID: videoID, url: url, status: status)
    }

    // MARK: - Metadata

    struct VideoResource: Encodable, Equatable {
        struct Snippet: Encodable, Equatable {
            var title: String
            var description: String
            var tags: [String]
            var categoryId: String
        }
        struct Status: Encodable, Equatable {
            var privacyStatus: String
            var selfDeclaredMadeForKids: Bool
        }
        var snippet: Snippet
        var status: Status
    }

    func metadata(for request: PublishRequest) -> VideoResource {
        VideoResource(snippet: .init(title: Self.title(for: request), description: Self.description(for: request),
                                     tags: Self.tags(request.tags), categoryId: categoryID),
                      status: .init(privacyStatus: request.visibility.rawValue, selfDeclaredMadeForKids: false))
    }

    /// ≤ 100 characters, no angle brackets (the API rejects them). Shorts get " #Shorts" when there's room and the title
    /// doesn't already carry the tag.
    static func title(for request: PublishRequest) -> String {
        var title = sanitize(request.title).trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty { title = request.file.deletingPathExtension().lastPathComponent }
        if title.count > maxTitleLength { title = String(title.prefix(maxTitleLength)).trimmingCharacters(in: .whitespaces) }
        if request.isShort, !title.localizedCaseInsensitiveContains("#shorts"),
           title.count + shortsSuffix.count <= maxTitleLength {
            title += shortsSuffix
        }
        return title
    }

    /// `fullDescription` (credits appended), ≤ 5000 bytes. When too long, the free text is cut so the credits survive.
    static func description(for request: PublishRequest) -> String {
        let full = sanitize(request.fullDescription)
        guard full.utf8.count > maxDescriptionBytes else { return full }
        let credits = sanitize(String(request.fullDescription.dropFirst(request.description.count)))
        let ellipsis = "…"
        let budget = maxDescriptionBytes - credits.utf8.count - ellipsis.utf8.count
        guard budget > 0 else {
            var trimmed = credits
            while trimmed.utf8.count > maxDescriptionBytes { trimmed.removeLast() }
            return trimmed
        }
        var text = sanitize(request.description)
        while text.utf8.count > budget { text.removeLast() }
        return text + ellipsis + credits
    }

    /// Tags without "#" or angle brackets, total length (counting separators) ≤ 500 characters.
    static func tags(_ tags: [String]) -> [String] {
        var result: [String] = []
        var length = 0
        for tag in tags {
            let clean = sanitize(tag).trimmingCharacters(in: CharacterSet(charactersIn: "#").union(.whitespaces))
            guard !clean.isEmpty, !result.contains(clean) else { continue }
            let cost = clean.count + (clean.contains(" ") ? 2 : 0) + (result.isEmpty ? 0 : 1)
            guard length + cost <= maxTagsLength else { break }
            result.append(clean)
            length += cost
        }
        return result
    }

    private static func sanitize(_ text: String) -> String {
        text.replacingOccurrences(of: "<", with: "‹").replacingOccurrences(of: ">", with: "›")
    }

    /// `<name>.<lang>.srt` → "lang"; anything else → "en".
    static func captionLanguage(for caption: URL, videoFile: URL? = nil) -> String {
        let stem = caption.deletingPathExtension().lastPathComponent   // "clip.es"
        var candidate: Substring?
        if let base = videoFile?.deletingPathExtension().lastPathComponent, stem.hasPrefix(base + ".") {
            candidate = stem.dropFirst(base.count + 1)
        } else if let dot = stem.lastIndex(of: ".") {
            candidate = stem[stem.index(after: dot)...]
        }
        guard let candidate, isLanguageTag(candidate) else { return "en" }
        return String(candidate)
    }

    private static func isLanguageTag(_ text: Substring) -> Bool {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard let first = parts.first, (2...3).contains(first.count), first.allSatisfy({ $0.isASCII && $0.isLetter }),
              parts.dropFirst().allSatisfy({ (2...8).contains($0.count) && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) } })
        else { return false }
        return Locale.LanguageCode(String(first).lowercased()).isISOLanguage
    }

    // MARK: - Resumable upload

    private func startSession(_ request: PublishRequest, size: Int64) async throws -> URL {
        var components = URLComponents(url: uploadBaseURL.appendingPathComponent("videos"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "uploadType", value: "resumable"),
                                 URLQueryItem(name: "part", value: "snippet,status")]
        let url = components.url!
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let body = try encoder.encode(metadata(for: request))
        let contentType = videoContentType(for: request.file)
        let (data, response) = try await http.authorizedSend(tokens, platform: .youtube, retry: retry, body: body) {
            var urlRequest = URLRequest(url: url)
            urlRequest.httpMethod = "POST"
            urlRequest.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
            urlRequest.setValue(String(size), forHTTPHeaderField: "X-Upload-Content-Length")
            urlRequest.setValue(contentType, forHTTPHeaderField: "X-Upload-Content-Type")
            return urlRequest
        }
        guard (200..<300).contains(response.statusCode) else { throw Self.apiError(data, status: response.statusCode) }
        guard let location = response.value(forHTTPHeaderField: "Location"),
              let sessionURL = URL(string: location, relativeTo: url)?.absoluteURL else {
            throw PublishError.invalidResponse("no upload session (Location header) from YouTube")
        }
        return sessionURL
    }

    private enum ChunkOutcome {
        case complete([String: Any])
        case incomplete(nextOffset: Int64)
        case transient(String)
    }

    private func uploadChunks(_ reader: FileChunkReader, to sessionURL: URL,
                              progress: (@Sendable (UploadProgress) -> Void)?) async throws -> [String: Any] {
        let total = reader.size
        var offset: Int64 = 0
        var failures = 0
        var needsStatus = false
        while true {
            try Task.checkCancellation()
            let outcome: ChunkOutcome
            do {
                if needsStatus || offset >= total {
                    outcome = try await putToSession(sessionURL, contentRange: "bytes */\(total)", body: Data())
                } else {
                    let end = min(offset + Int64(chunkSize), total)
                    let chunk = try reader.read(offset..<end)
                    outcome = try await putToSession(sessionURL, contentRange: "bytes \(offset)-\(end - 1)/\(total)", body: chunk)
                }
            } catch let error where RetryPolicy.isTransient(error) {
                outcome = .transient(error.localizedDescription)
            }
            switch outcome {
            case .complete(let video):
                return video
            case .incomplete(let next):
                offset = next
                failures = 0
                needsStatus = false
                progress?(UploadProgress(fraction: 0.9 * Double(offset) / Double(total),
                                         message: "Uploading to YouTube (\(Self.megabytes(offset)) of \(Self.megabytes(total)))"))
            case .transient(let message):
                failures += 1
                guard failures <= retry.maxRetries else { throw PublishError.retriesExhausted(message) }
                progress?(UploadProgress(fraction: 0.9 * Double(offset) / Double(total),
                                         message: "Connection problem (\(message)); retrying…"))
                try await Task.sleep(for: retry.delay(forAttempt: failures))
                needsStatus = true
            }
        }
    }

    /// One PUT to the session URI (a chunk, or an empty status query) classified per the resumable protocol.
    private func putToSession(_ sessionURL: URL, contentRange: String, body: Data) async throws -> ChunkOutcome {
        // No retry here: after a transient failure the caller asks for the status before resending.
        let (data, response) = try await http.authorizedSend(tokens, platform: .youtube, retry: RetryPolicy(maxRetries: 0),
                                                             body: body) {
            var request = URLRequest(url: sessionURL)
            request.httpMethod = "PUT"
            request.setValue(contentRange, forHTTPHeaderField: "Content-Range")
            request.setValue(String(body.count), forHTTPHeaderField: "Content-Length")
            return request
        }
        switch response.statusCode {
        case 200, 201:
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw PublishError.invalidResponse("upload finished but the video resource wasn't JSON")
            }
            return .complete(json)
        case 308:
            return .incomplete(nextOffset: Self.nextOffset(fromRange: response.value(forHTTPHeaderField: "Range")))
        case let status where RetryPolicy.isTransient(status: status):
            return .transient("HTTP \(status)")
        case 404, 410:
            throw PublishError.uploadSessionExpired
        default:
            throw Self.apiError(data, status: response.statusCode)
        }
    }

    /// "bytes=0-999999" → 1_000_000; missing header → 0 (nothing stored yet).
    static func nextOffset(fromRange header: String?) -> Int64 {
        guard let header, let dash = header.lastIndex(of: "-"),
              let last = Int64(header[header.index(after: dash)...].trimmingCharacters(in: .whitespaces)) else { return 0 }
        return last + 1
    }

    // MARK: - Captions

    private func uploadCaption(_ file: URL, language: String, videoID: String) async throws {
        let srt = try Data(contentsOf: file)
        let name = Locale(identifier: "en").localizedString(forIdentifier: language) ?? language
        let snippet: [String: Any] = ["snippet": ["videoId": videoID, "language": language, "name": name, "isDraft": false]]
        let metadata = try JSONSerialization.data(withJSONObject: snippet, options: [.sortedKeys])
        let boundary = "clipper-\(UUID().uuidString)"
        var body = Data()
        body.append(Data("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n".utf8))
        body.append(metadata)
        body.append(Data("\r\n--\(boundary)\r\nContent-Type: application/octet-stream\r\n\r\n".utf8))
        body.append(srt)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        var components = URLComponents(url: uploadBaseURL.appendingPathComponent("captions"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "uploadType", value: "multipart"), URLQueryItem(name: "part", value: "snippet")]
        let url = components.url!
        let (data, response) = try await http.authorizedSend(tokens, platform: .youtube, retry: retry, body: body) {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            return request
        }
        guard (200..<300).contains(response.statusCode) else { throw Self.apiError(data, status: response.statusCode) }
    }

    // MARK: - Helpers

    /// Google errors: {"error": {"code": 403, "message": "...", "errors": [{"reason": "quotaExceeded", ...}]}}.
    static func apiError(_ data: Data, status: Int) -> PublishError {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = json["error"] as? [String: Any] else {
            return .http(status: status, body: data.utf8Text)
        }
        let reason = ((error["errors"] as? [[String: Any]])?.first?["reason"] as? String) ?? (error["status"] as? String) ?? "\(status)"
        var message = (error["message"] as? String) ?? "HTTP \(status)"
        if status == 403, reason == "insufficientPermissions" || reason == "forbidden" {
            message += " (reconnect YouTube to grant the upload and caption scopes)"
        }
        return .api(platform: .youtube, code: reason, message: message)
    }

    static func megabytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

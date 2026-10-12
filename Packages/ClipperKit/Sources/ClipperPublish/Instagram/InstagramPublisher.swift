@preconcurrency import AVFoundation
import Foundation

/// Publishes a Reel through the Instagram API with Instagram Login (professional account, no Facebook Page).
///
/// Instagram only accepts a *public URL* for the video, so with no backend the file goes through the user's own
/// S3-compatible bucket (Cloudflare R2 recommended):
/// 1. validate locally (Reel limits, caption) — nothing is uploaded if this fails;
/// 2. refresh the token if it is older than 50 days; check the 24 h publishing quota;
/// 3. upload to `clipper-tmp/<uuid>/<name>` and presign a GET URL valid for 1 h;
/// 4. `POST /<IG_ID>/media` (`media_type=REELS`, `video_url`, `caption`, `share_to_feed=true`) → container id;
/// 5. poll `GET /<container>?fields=status_code,status` until `FINISHED` (`ERROR`/`EXPIRED` fail; 10 min timeout);
/// 6. `POST /<IG_ID>/media_publish` (`creation_id`) → media id; `GET /<media>?fields=permalink`;
/// 7. delete the temporary object — always, also when any step above failed or the task was cancelled.
///
/// Docs: https://developers.facebook.com/docs/instagram-platform/content-publishing
public struct InstagramPublisher: Publisher {
    public struct Options: Sendable {
        /// First status poll delay; grows by `pollInterval` per poll up to `maxPollInterval`.
        public var pollInterval: Duration
        public var maxPollInterval: Duration
        public var processingTimeout: Duration
        /// Lifetime of the presigned video URL Instagram downloads from.
        public var presignExpiry: Duration
        public var keyPrefix: String
        public var shareToFeed: Bool
        public var checkQuota: Bool
        public var storage: S3Client.Options

        public init(pollInterval: Duration = .seconds(5), maxPollInterval: Duration = .seconds(30),
                    processingTimeout: Duration = .seconds(600), presignExpiry: Duration = .seconds(3600),
                    keyPrefix: String = "clipper-tmp/", shareToFeed: Bool = true, checkQuota: Bool = true,
                    storage: S3Client.Options = S3Client.Options()) {
            self.pollInterval = pollInterval; self.maxPollInterval = maxPollInterval
            self.processingTimeout = processingTimeout; self.presignExpiry = presignExpiry; self.keyPrefix = keyPrefix
            self.shareToFeed = shareToFeed; self.checkQuota = checkQuota; self.storage = storage
        }
    }

    public typealias Probe = @Sendable (URL) async throws -> InstagramReels.VideoFacts

    public let platform = Platform.instagram
    public let credentials: any CredentialStore
    public let endpoints: InstagramEndpoints
    public let options: Options
    let session: URLSession
    let probe: Probe
    let now: @Sendable () -> Date

    public init(credentials: any CredentialStore, endpoints: InstagramEndpoints = InstagramEndpoints(),
                session: URLSession = URLSession(configuration: .ephemeral), options: Options = Options(),
                probe: Probe? = nil, now: @escaping @Sendable () -> Date = { Date() }) {
        self.credentials = credentials; self.endpoints = endpoints; self.session = session; self.options = options
        self.probe = probe ?? Self.probeWithAVFoundation; self.now = now
    }

    public var auth: InstagramAuth { InstagramAuth(credentials: credentials, endpoints: endpoints, session: session, now: now) }

    public func isConnected() async -> Bool {
        guard let token = try? auth.storedToken(), !token.isExpired(at: now()) else { return false }
        return (try? storageConfig()) != nil
    }

    func storageConfig() throws -> S3Config {
        guard let config = try credentials.decode(S3Config.self, InstagramCredentialKeys.storage) else {
            throw InstagramError.notConnected("no bucket configured under \(InstagramCredentialKeys.storage) — Instagram needs a public video URL (see docs/publishing.md#instagram)")
        }
        return config
    }

    // MARK: Publish

    public func publish(_ request: PublishRequest, progress: (@Sendable (UploadProgress) -> Void)?) async throws -> PublishResult {
        let report: @Sendable (Double, String) -> Void = { fraction, message in
            progress?(UploadProgress(fraction: fraction, message: message))
        }

        // 1. Local checks: configuration, file, caption. No network yet.
        guard try auth.storedToken() != nil else {
            throw InstagramError.notConnected("no token stored under \(InstagramCredentialKeys.token) — log in first")
        }
        let storage = try S3Client(config: try storageConfig(), options: options.storage, session: session, now: now)
        report(0, "Checking video")
        let (caption, notes) = try await preflight(request)

        // 2. Token + quota.
        let (token, refreshWarning) = try await auth.validToken()
        let http = InstagramHTTP(session: session)
        if options.checkQuota { try await checkQuota(token, http) }

        // 3–7.
        let key = Self.temporaryKey(prefix: options.keyPrefix, file: request.file)
        var outcome: Result<(mediaID: String, permalink: URL?), any Error>
        do {
            outcome = .success(try await upload(request, key: key, caption: caption, token: token, storage: storage,
                                                http: http, report: report))
        } catch {
            outcome = .failure(error)
        }
        // Not inheriting cancellation: the temporary object goes away even if the publish task was cancelled.
        report(0.97, "Removing temporary upload")
        let cleanup = await Task { () -> String? in
            do { try await storage.deleteObject(key: key); return nil } catch { return error.localizedDescription }
        }.value

        let (mediaID, permalink) = try outcome.get()
        var status = "published as a Reel" + (options.shareToFeed ? " (also shared to feed)" : "")
        let extra = notes + [refreshWarning, cleanup.map { "temporary file \(key) could not be deleted: \($0)" }].compactMap { $0 }
        if !extra.isEmpty { status += "; " + extra.joined(separator: "; ") }
        report(1, "Published")
        return PublishResult(platform: .instagram, remoteID: mediaID, url: permalink, status: status)
    }

    /// Validates the request and builds the caption. Throws `InstagramError.validation` listing every problem.
    public func preflight(_ request: PublishRequest) async throws -> (caption: String, notes: [String]) {
        let attributes = try? FileManager.default.attributesOfItem(atPath: request.file.path)
        guard let size = attributes?[.size] as? Int64 else {
            throw InstagramError.validation(["file not found: \(request.file.path)"])
        }
        var facts: InstagramReels.VideoFacts?
        var problems: [String] = []
        do { facts = try await probe(request.file) } catch {
            problems.append("could not read the video: \(error.localizedDescription)")
        }
        let check = InstagramReels.check(fileExtension: request.file.pathExtension, fileSize: size, facts: facts,
                                         visibility: request.visibility)
        problems += check.problems
        var caption = ""
        do { caption = try InstagramCaption.build(request) } catch let InstagramError.validation(captionProblems) {
            problems += captionProblems
        }
        guard problems.isEmpty else { throw InstagramError.validation(problems) }
        return (caption, check.notes)
    }

    private func checkQuota(_ token: InstagramToken, _ http: InstagramHTTP) async throws {
        do {
            let data = try await http.get(endpoints.graph, path: "\(endpoints.version)/\(token.userID)/content_publishing_limit",
                                          query: [("fields", "quota_usage,config"), ("access_token", token.accessToken)])
            let limit = try http.decode(PublishingLimit.self, data, "content_publishing_limit")
            if let entry = limit.data?.first, let used = entry.quota_usage, let total = entry.config?.quota_total, used >= total {
                throw InstagramError.quotaExceeded(used: used, total: total)
            }
        } catch let error as InstagramError {
            // Only a definite answer blocks the upload: exhausted quota or a dead token.
            switch error {
            case .quotaExceeded: throw error
            case let .api(_, code, _, _) where code == 190: throw error
            default: return
            }
        } catch {
            return
        }
    }

    private func upload(_ request: PublishRequest, key: String, caption: String, token: InstagramToken,
                        storage: S3Client, http: InstagramHTTP,
                        report: @escaping @Sendable (Double, String) -> Void) async throws -> (mediaID: String, permalink: URL?) {
        let contentType = request.file.pathExtension.lowercased() == "mov" ? "video/quicktime" : "video/mp4"
        report(0.02, "Uploading to storage")
        try await storage.putObject(file: request.file, key: key, contentType: contentType) { fraction in
            report(0.02 + 0.48 * fraction, "Uploading to storage")
        }
        let videoURL = try storage.presignedGetURL(key: key, expires: options.presignExpiry)

        report(0.5, "Creating Instagram container")
        let version = endpoints.version
        var form: [(String, String)] = [("media_type", "REELS"), ("video_url", videoURL.absoluteString)]
        if !caption.isEmpty { form.append(("caption", caption)) }
        form += [("share_to_feed", options.shareToFeed ? "true" : "false"), ("access_token", token.accessToken)]
        let created = try http.decode(IDResponse.self,
                                      try await http.post(endpoints.graph, path: "\(version)/\(token.userID)/media", form: form),
                                      "media container")

        try await waitUntilFinished(container: created.id.value, token: token, http: http, report: report)

        report(0.92, "Publishing")
        let published = try http.decode(IDResponse.self, try await http.post(
            endpoints.graph, path: "\(version)/\(token.userID)/media_publish",
            form: [("creation_id", created.id.value), ("access_token", token.accessToken)]), "media_publish")

        // The Reel is live at this point; a missing permalink is not a failure.
        var permalink: URL?
        if let data = try? await http.get(endpoints.graph, path: "\(version)/\(published.id.value)",
                                          query: [("fields", "permalink"), ("access_token", token.accessToken)]),
           let link = (try? JSONDecoder().decode(PermalinkResponse.self, from: data))?.permalink {
            permalink = URL(string: link)
        }
        return (published.id.value, permalink)
    }

    private func waitUntilFinished(container: String, token: InstagramToken, http: InstagramHTTP,
                                   report: @Sendable (Double, String) -> Void) async throws {
        let clock = ContinuousClock()
        let start = clock.now
        var delay = options.pollInterval
        let timeout = options.processingTimeout
        while true {
            let data = try await http.get(endpoints.graph, path: "\(endpoints.version)/\(container)",
                                          query: [("fields", "status_code,status"), ("access_token", token.accessToken)])
            let status = try http.decode(ContainerStatus.self, data, "container status")
            switch status.status_code ?? "" {
            case "FINISHED", "PUBLISHED": return
            case "ERROR", "EXPIRED": throw InstagramError.processingFailed(statusCode: status.status_code!, status: status.status)
            default: break   // IN_PROGRESS (or not reported yet)
            }
            let elapsed = clock.now - start
            if elapsed >= timeout { throw InstagramError.processingTimedOut(seconds: Int((timeout / .seconds(1)).rounded(.up))) }
            report(0.5 + 0.4 * min(1, elapsed / timeout), "Instagram is processing the video")
            try await Task.sleep(for: min(delay, timeout - elapsed))
            delay = min(delay + options.pollInterval, options.maxPollInterval)
        }
    }

    /// `clipper-tmp/<uuid>/<safe-name>` — unguessable, so the short-lived URL is the only way to find it.
    static func temporaryKey(prefix: String, file: URL) -> String {
        let safe = String(file.lastPathComponent.unicodeScalars.map { scalar -> Character in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || "-_.".unicodeScalars.contains(scalar))
                ? Character(scalar) : "_"
        })
        return "\(prefix)\(UUID().uuidString.lowercased())/\(safe.isEmpty ? "video.mp4" : safe)"
    }

    // MARK: Probe

    /// Duration and display size (rotation applied) via AVFoundation.
    @Sendable public static func probeWithAVFoundation(_ url: URL) async throws -> InstagramReels.VideoFacts {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw InstagramError.validation(["the file has no video track"])
        }
        let (size, transform) = try await track.load(.naturalSize, .preferredTransform)
        let display = CGRect(origin: .zero, size: size).applying(transform).size
        return InstagramReels.VideoFacts(duration: duration.seconds, width: Int(abs(display.width).rounded()),
                                         height: Int(abs(display.height).rounded()))
    }

    // MARK: Wire types

    struct IDResponse: Decodable { var id: InstagramFlexibleID }
    struct ContainerStatus: Decodable { var status_code: String?; var status: String? }
    struct PermalinkResponse: Decodable { var permalink: String? }
    struct PublishingLimit: Decodable {
        struct Entry: Decodable {
            struct Config: Decodable { var quota_total: Int?; var quota_duration: Int? }
            var quota_usage: Int?
            var config: Config?
        }
        var data: [Entry]?
    }
}

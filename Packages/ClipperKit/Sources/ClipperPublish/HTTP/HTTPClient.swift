import Foundation

/// Errors from publishing: OAuth, HTTP, and platform API failures. `errorDescription` is shown to the user.
public enum PublishError: Error, Sendable, Equatable, LocalizedError {
    case missingCredentials(Platform, [String])
    case notConnected(Platform)
    case unsupportedPlatform(Platform)
    case invalidFile(String)
    case http(status: Int, body: String)
    case invalidResponse(String)
    case api(platform: Platform, code: String, message: String)
    case uploadSessionExpired
    case retriesExhausted(String)
    case publishFailed(platform: Platform, reason: String)

    public var errorDescription: String? {
        switch self {
        case .missingCredentials(let platform, let keys):
            "\(platform.displayName) isn't set up: missing \(keys.joined(separator: ", "))."
        case .notConnected(let platform): "\(platform.displayName) isn't connected. Connect the account first."
        case .unsupportedPlatform(let platform): "Publishing to \(platform.displayName) isn't supported yet."
        case .invalidFile(let message): "Can't upload the file: \(message)"
        case .http(let status, let body): "HTTP \(status): \(body.prefix(500))"
        case .invalidResponse(let message): "Unexpected response: \(message)"
        case .api(let platform, let code, let message): "\(platform.displayName) API error \(code): \(message)"
        case .uploadSessionExpired: "The upload session expired; start the upload again."
        case .retriesExhausted(let message): "Gave up after repeated failures: \(message)"
        case .publishFailed(let platform, let reason): "\(platform.displayName) rejected the upload: \(reason)"
        }
    }
}

/// Exponential backoff for transient failures (5xx, dropped connections).
public struct RetryPolicy: Sendable {
    public var maxRetries: Int
    public var baseDelay: Duration
    public var maxDelay: Duration
    public init(maxRetries: Int = 6, baseDelay: Duration = .seconds(1), maxDelay: Duration = .seconds(32)) {
        self.maxRetries = maxRetries; self.baseDelay = baseDelay; self.maxDelay = maxDelay
    }
    public static let standard = RetryPolicy()

    /// Delay before retry number `attempt` (1-based): base * 2^(attempt-1), capped, with up to 25% jitter.
    func delay(forAttempt attempt: Int) -> Duration {
        let exponential = baseDelay * (1 << min(max(attempt - 1, 0), 20))
        let capped = min(exponential, maxDelay)
        return capped + capped * Double.random(in: 0...0.25)
    }

    static func isTransient(status: Int) -> Bool { [500, 502, 503, 504].contains(status) }
    static func isTransient(_ error: Error) -> Bool {
        guard let error = error as? URLError else { return false }
        return [.timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost,
                .dnsLookupFailed, .cannotFindHost, .resourceUnavailable].contains(error.code)
    }

    /// Failures that happen before the request reaches the server, so even a non-idempotent request is safe to resend.
    static func wasNotSent(_ error: Error) -> Bool {
        guard let error = error as? URLError else { return false }
        return [.notConnectedToInternet, .cannotConnectToHost, .dnsLookupFailed, .cannotFindHost].contains(error.code)
    }

    /// Methods that can be repeated without a second side effect (RFC 9110 §9.2.2). POSTs aren't: resending one after
    /// a lost connection or timeout can replay a one-time authorization code or create a second TikTok upload.
    static func isIdempotent(_ request: URLRequest) -> Bool {
        ["GET", "HEAD", "PUT", "DELETE", "OPTIONS"].contains((request.httpMethod ?? "GET").uppercased())
    }
}

/// Thin URLSession wrapper: never follows redirects (YouTube's "308 Resume Incomplete" must reach the caller), ephemeral
/// session (no cookies/cache on disk).
struct HTTPClient: Sendable {
    let session: URLSession

    static let defaultSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 60 * 60
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    init(session: URLSession = HTTPClient.defaultSession) { self.session = session }

    func send(_ request: URLRequest, body: Data? = nil) async throws -> (Data, HTTPURLResponse) {
        let delegate = NoRedirectDelegate()
        let (data, response): (Data, URLResponse)
        if let body {
            (data, response) = try await session.upload(for: request, from: body, delegate: delegate)
        } else {
            (data, response) = try await session.data(for: request, delegate: delegate)
        }
        guard let http = response as? HTTPURLResponse else { throw PublishError.invalidResponse("not an HTTP response") }
        return (data, http)
    }

    /// Sends a request built by `make` (rebuilt per attempt so tokens stay fresh), retrying transient failures. A
    /// non-idempotent request (POST) is only resent after a connection error when it can't have reached the server.
    func sendWithRetry(_ policy: RetryPolicy, body: Data? = nil,
                       make: () async throws -> URLRequest) async throws -> (Data, HTTPURLResponse) {
        var attempt = 0
        while true {
            try Task.checkCancellation()
            var idempotent = true
            do {
                let request = try await make()
                idempotent = RetryPolicy.isIdempotent(request)
                let result = try await send(request, body: body)
                if RetryPolicy.isTransient(status: result.1.statusCode), attempt < policy.maxRetries {
                    attempt += 1
                    try await Task.sleep(for: policy.delay(forAttempt: attempt))
                    continue
                }
                return result
            } catch where RetryPolicy.isTransient(error) && (idempotent || RetryPolicy.wasNotSent(error)) && attempt < policy.maxRetries {
                attempt += 1
                try await Task.sleep(for: policy.delay(forAttempt: attempt))
            }
        }
    }

    static func formBody(_ fields: [(String, String)]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let encoded = fields.map { name, value in
            "\(name.addingPercentEncoding(withAllowedCharacters: allowed) ?? name)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
        }
        return Data(encoded.joined(separator: "&").utf8)
    }
}

private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? { nil }
}

extension Data {
    var utf8Text: String { String(decoding: self, as: UTF8.self) }
}

/// Reads byte ranges of a file without loading the whole file.
final class FileChunkReader {
    let handle: FileHandle
    let size: Int64

    init(url: URL) throws {
        let attributes: [FileAttributeKey: Any]
        do { attributes = try FileManager.default.attributesOfItem(atPath: url.path) }
        catch { throw PublishError.invalidFile("\(url.lastPathComponent) not found") }
        size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard size > 0 else { throw PublishError.invalidFile("\(url.lastPathComponent) is empty") }
        handle = try FileHandle(forReadingFrom: url)
    }

    func read(_ range: Range<Int64>) throws -> Data {
        try handle.seek(toOffset: UInt64(range.lowerBound))
        let data = try handle.read(upToCount: Int(range.count)) ?? Data()
        guard data.count == range.count else { throw PublishError.invalidFile("file changed while uploading") }
        return data
    }

    deinit { try? handle.close() }
}

extension HTTPClient {
    /// `sendWithRetry` with a bearer token from `tokens` (refreshed when about to expire), plus one forced refresh and
    /// resend if the server answers 401.
    func authorizedSend(_ tokens: TokenManager, platform: Platform, retry: RetryPolicy, body: Data? = nil,
                        make: () -> URLRequest) async throws -> (Data, HTTPURLResponse) {
        var refreshed = false
        while true {
            let result = try await sendWithRetry(retry, body: body) {
                guard let token = try await tokens.validToken() else { throw PublishError.notConnected(platform) }
                var request = make()
                request.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
                return request
            }
            if result.1.statusCode == 401, !refreshed {
                refreshed = true
                _ = try await tokens.refreshNow()
                continue
            }
            return result
        }
    }
}

/// MIME type for an exported video file.
func videoContentType(for url: URL) -> String {
    switch url.pathExtension.lowercased() {
    case "mp4", "m4v": "video/mp4"
    case "mov": "video/quicktime"
    case "webm": "video/webm"
    default: "application/octet-stream"
    }
}

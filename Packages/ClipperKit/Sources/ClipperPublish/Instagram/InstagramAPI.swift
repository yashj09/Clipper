import Foundation

/// Credential-store keys used by the Instagram publisher (all strings unless noted).
public enum InstagramCredentialKeys {
    /// Instagram app ID (App Dashboard → Instagram → API setup with Instagram login; not the Meta app ID).
    public static let appID = "instagram.app_id"
    /// Instagram app secret (same page). Needed only for the initial login (code → token exchange).
    public static let appSecret = "instagram.app_secret"
    /// HTTPS redirect URI exactly as registered under "Set up Instagram business login".
    public static let redirectURI = "instagram.redirect_uri"
    /// JSON `InstagramToken` (long-lived token, professional account id, issue/expiry dates).
    public static let token = "instagram.token"
    /// JSON `S3Config` for the temporary public video URL (shared key `storage.s3`).
    public static let storage = S3Config.credentialKey
}

/// Hosts and Graph API version. Injectable so tests can point everything at a local mock server.
public struct InstagramEndpoints: Sendable, Equatable {
    /// Current version used throughout Meta's Instagram Platform docs (verified Oct 2026).
    public static let defaultVersion = "v25.0"

    /// `https://graph.instagram.com` — Graph API for Instagram Login (media, publish, token exchange/refresh).
    public var graph: URL
    /// `https://api.instagram.com` — short-lived token exchange (`/oauth/access_token`).
    public var api: URL
    /// `https://www.instagram.com/oauth/authorize` — consent screen.
    public var authorize: URL
    public var version: String

    public init(graph: URL = URL(string: "https://graph.instagram.com")!,
                api: URL = URL(string: "https://api.instagram.com")!,
                authorize: URL = URL(string: "https://www.instagram.com/oauth/authorize")!,
                version: String = InstagramEndpoints.defaultVersion) {
        self.graph = graph; self.api = api; self.authorize = authorize; self.version = version
    }

    /// Every host on one base URL (tests).
    public static func mock(_ base: URL, version: String = defaultVersion) -> InstagramEndpoints {
        InstagramEndpoints(graph: base, api: base, authorize: base.appendingPathComponent("oauth/authorize"), version: version)
    }
}

/// A long-lived Instagram User access token plus the professional account it belongs to.
public struct InstagramToken: Codable, Sendable, Equatable {
    /// Instagram professional account id (`user_id` from `/me`) used as `<IG_ID>` in publishing calls.
    public var userID: String
    public var username: String?
    public var accessToken: String
    /// When this token was issued or last refreshed.
    public var issuedAt: Date
    /// Expiry reported by Meta (`expires_in`, ~60 days); nil if unknown.
    public var expiresAt: Date?

    public init(userID: String, username: String? = nil, accessToken: String, issuedAt: Date, expiresAt: Date?) {
        self.userID = userID; self.username = username; self.accessToken = accessToken
        self.issuedAt = issuedAt; self.expiresAt = expiresAt
    }

    public func isExpired(at now: Date) -> Bool { expiresAt.map { now >= $0 } ?? false }
}

public enum InstagramError: Error, LocalizedError, Equatable {
    /// Missing configuration or token; the message says what to set up.
    case notConnected(String)
    /// Pre-upload checks failed; every problem is listed.
    case validation([String])
    /// The pasted redirect URL was unusable, the state did not match, or the user denied access.
    case authorization(String)
    /// Graph API error object (`code` 190 = invalid/expired token).
    case api(status: Int, code: Int?, subcode: Int?, message: String)
    /// Container finished with `ERROR` or `EXPIRED`.
    case processingFailed(statusCode: String, status: String?)
    case processingTimedOut(seconds: Int)
    /// The rolling 24 h publishing quota is used up.
    case quotaExceeded(used: Int, total: Int)
    case malformedResponse(String)

    public var errorDescription: String? {
        switch self {
        case let .notConnected(why): "Instagram is not connected: \(why)"
        case let .validation(problems): "Video can't be published as a Reel:\n- " + problems.joined(separator: "\n- ")
        case let .authorization(why): "Instagram login failed: \(why)"
        case let .api(status, code, subcode, message):
            "Instagram API error (HTTP \(status)\(code.map { ", code \($0)" } ?? "")\(subcode.map { "/\($0)" } ?? "")): \(message)"
                + (code == 190 ? " — reconnect Instagram." : "")
        case let .processingFailed(code, status): "Instagram could not process the video (\(code))\(status.map { ": \($0)" } ?? "")"
        case let .processingTimedOut(s): "Instagram did not finish processing the video within \(s) s"
        case let .quotaExceeded(used, total): "Instagram publishing limit reached (\(used)/\(total) posts in 24 h)"
        case let .malformedResponse(why): "Unexpected Instagram response: \(why)"
        }
    }
}

/// Thin HTTP layer over the Instagram Graph API: form-encoded POSTs, query GETs, Graph error decoding.
struct InstagramHTTP: Sendable {
    let session: URLSession

    func get(_ base: URL, path: String, query: [(String, String)]) async throws -> Data {
        var components = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        components.percentEncodedQuery = Self.formEncode(query)
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 60
        return try await send(request)
    }

    func post(_ base: URL, path: String, form: [(String, String)]) async throws -> Data {
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(Self.formEncode(form).utf8)
        return try await send(request)
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw InstagramError.malformedResponse("not HTTP") }
        // Graph returns errors as {"error": {...}} — sometimes with HTTP 200.
        if let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: data), let error = envelope.error {
            throw InstagramError.api(status: http.statusCode, code: error.code, subcode: error.error_subcode,
                                     message: error.error_user_msg ?? error.message ?? "unknown error")
        }
        // api.instagram.com/oauth/access_token uses a flat error shape.
        if !(200..<300).contains(http.statusCode) {
            let flat = try? JSONDecoder().decode(FlatError.self, from: data)
            let message = flat?.error_message ?? flat?.error_description
                ?? String(decoding: data.prefix(300), as: UTF8.self)
            throw InstagramError.api(status: http.statusCode, code: flat?.code, subcode: nil, message: message)
        }
        return data
    }

    func decode<T: Decodable>(_ type: T.Type, _ data: Data, _ what: String) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: data) } catch {
            throw InstagramError.malformedResponse("\(what): \(String(decoding: data.prefix(200), as: UTF8.self))")
        }
    }

    /// `application/x-www-form-urlencoded` with RFC 3986 unreserved characters left as-is.
    static func formEncode(_ items: [(String, String)]) -> String {
        items.map { "\(SigV4Signer.uriEncode($0.0))=\(SigV4Signer.uriEncode($0.1))" }.joined(separator: "&")
    }

    private struct ErrorEnvelope: Decodable {
        struct Body: Decodable {
            var message: String?
            var type: String?
            var code: Int?
            var error_subcode: Int?
            var error_user_msg: String?
        }
        var error: Body?
    }

    private struct FlatError: Decodable {
        var error_type: String?
        var code: Int?
        var error_message: String?
        var error_description: String?
    }
}

/// Decodes an id that Meta sometimes sends as a JSON number and sometimes as a string.
struct InstagramFlexibleID: Decodable, Sendable {
    var value: String
    init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { value = s }
        else if let n = try? c.decode(Int64.self) { value = String(n) }
        else { value = String(try c.decode(UInt64.self)) }
    }
}

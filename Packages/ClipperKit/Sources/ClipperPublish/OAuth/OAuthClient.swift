import Foundation
import Synchronization

/// An OAuth 2.0 provider configuration for a desktop ("installed") app using the authorization-code flow with PKCE and a
/// loopback redirect (RFC 8252 §7.3).
public struct OAuthConfig: Sendable, Equatable {
    public var authorizeURL: URL
    public var tokenURL: URL
    public var clientID: String
    /// Desktop clients still send a secret to Google and TikTok; it is not truly confidential in a desktop app.
    public var clientSecret: String?
    public var scopes: [String]
    /// Google joins scopes with spaces, TikTok with commas.
    public var scopeSeparator: String
    /// Provider-specific authorize parameters, e.g. Google's `access_type=offline`.
    public var extraAuthParams: [String: String]
    public var pkceMethod: PKCEMethod
    /// "client_id" (RFC 6749, Google) or "client_key" (TikTok).
    public var clientIDParamName: String
    /// Path of the loopback redirect URI. TikTok requires it to match the registered URI exactly (except the port).
    public var redirectPath: String

    public init(authorizeURL: URL, tokenURL: URL, clientID: String, clientSecret: String? = nil, scopes: [String],
                scopeSeparator: String = " ", extraAuthParams: [String: String] = [:], pkceMethod: PKCEMethod = .s256,
                clientIDParamName: String = "client_id", redirectPath: String = "/callback") {
        self.authorizeURL = authorizeURL; self.tokenURL = tokenURL; self.clientID = clientID
        self.clientSecret = clientSecret; self.scopes = scopes; self.scopeSeparator = scopeSeparator
        self.extraAuthParams = extraAuthParams; self.pkceMethod = pkceMethod
        self.clientIDParamName = clientIDParamName; self.redirectPath = redirectPath
    }
}

/// Tokens returned by the token endpoint; stored as JSON in the CredentialStore.
public struct OAuthToken: Codable, Sendable, Equatable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date?
    public var scope: String?
    public var tokenType: String?
    /// Provider user id when returned (TikTok `open_id`).
    public var userID: String?

    public init(accessToken: String, refreshToken: String? = nil, expiresAt: Date? = nil, scope: String? = nil,
                tokenType: String? = "Bearer", userID: String? = nil) {
        self.accessToken = accessToken; self.refreshToken = refreshToken; self.expiresAt = expiresAt
        self.scope = scope; self.tokenType = tokenType; self.userID = userID
    }

    public func expires(within interval: TimeInterval, now: Date = Date()) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt.timeIntervalSince(now) <= interval
    }
}

public enum OAuthError: Error, Sendable, Equatable, LocalizedError {
    case stateMismatch
    /// The provider redirected back with `error=` (e.g. the user pressed Cancel: "access_denied").
    case authorizationDenied(error: String, description: String?)
    case missingCode
    case timedOut
    case tokenEndpoint(status: Int, error: String, description: String?)
    case invalidTokenResponse(String)
    case noRefreshToken

    public var errorDescription: String? {
        switch self {
        case .stateMismatch: "Sign-in failed: the browser response didn't match this request (state mismatch)."
        case .authorizationDenied(let error, let description):
            "Sign-in was not granted (\(error))" + (description.map { ": \($0)" } ?? ".")
        case .missingCode: "Sign-in failed: no authorization code in the browser response."
        case .timedOut: "Sign-in timed out waiting for the browser."
        case .tokenEndpoint(let status, let error, let description):
            "Token request failed (HTTP \(status), \(error))" + (description.map { ": \($0)" } ?? ".")
        case .invalidTokenResponse(let message): "Token response was invalid: \(message)"
        case .noRefreshToken: "The saved sign-in can't be refreshed; connect the account again."
        }
    }
}

/// Runs the browser sign-in and token exchanges for one provider.
public struct OAuthClient: Sendable {
    public let config: OAuthConfig
    let http: HTTPClient

    public init(config: OAuthConfig, session: URLSession? = nil) {
        self.config = config
        self.http = session.map(HTTPClient.init(session:)) ?? HTTPClient()
    }

    /// Opens the provider's consent page (via `open`, which should launch the default browser) and waits for the redirect
    /// to a one-shot HTTP listener on 127.0.0.1:<ephemeral port>. Throws `OAuthError.timedOut` after `timeout`, and
    /// `CancellationError` if the calling task is cancelled.
    public func authorize(timeout: Duration = .seconds(300), open: @Sendable (URL) -> Void) async throws -> OAuthToken {
        let pkce = PKCE.generate(method: config.pkceMethod)
        let state = PKCE.randomString(length: 32)
        let redirectPath = config.redirectPath
        let (callbacks, continuation) = AsyncStream<Result<String, OAuthError>>.makeStream(bufferingPolicy: .bufferingOldest(1))

        let server = LoopbackHTTPServer(maxBodySize: 64 << 10) { request in
            guard request.path == redirectPath else { return HTTPServerResponse(status: 404) }
            let outcome = Self.callbackOutcome(request, expectedState: state)
            continuation.yield(outcome)
            switch outcome {
            case .success: return .html(Self.page(title: "Signed in to Clipper",
                                                  message: "You can close this window and return to Clipper."))
            case .failure(let error): return .html(Self.page(title: "Clipper sign-in failed",
                                                             message: error.errorDescription ?? "Unknown error"), status: 400)
            }
        }
        let port = try await server.start()
        defer { server.stop(); continuation.finish() }

        let redirectURI = "http://127.0.0.1:\(port)\(redirectPath)"
        open(authorizationURL(redirectURI: redirectURI, state: state, pkce: pkce))

        let code: String = try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                for await outcome in callbacks { return try outcome.get() }
                try Task.checkCancellation()
                throw CancellationError()
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw OAuthError.timedOut
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
        return try await exchange(code: code, redirectURI: redirectURI, verifier: pkce.verifier)
    }

    /// The consent-page URL for a given redirect URI, state and PKCE pair.
    public func authorizationURL(redirectURI: String, state: String, pkce: PKCE) -> URL {
        var components = URLComponents(url: config.authorizeURL, resolvingAgainstBaseURL: false)!
        var items = components.queryItems ?? []
        items += [
            URLQueryItem(name: config.clientIDParamName, value: config.clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: config.scopes.joined(separator: config.scopeSeparator)),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: pkce.challengeMethodParameter),
        ]
        items += config.extraAuthParams.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        components.queryItems = items
        // URLComponents leaves "+" and "/"-style characters alone; encode "+" so it isn't read as a space.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url!
    }

    public func exchange(code: String, redirectURI: String, verifier: String) async throws -> OAuthToken {
        var fields = [("grant_type", "authorization_code"), ("code", code), ("redirect_uri", redirectURI),
                      ("code_verifier", verifier), (config.clientIDParamName, config.clientID)]
        if let secret = config.clientSecret, !secret.isEmpty { fields.append(("client_secret", secret)) }
        return try await tokenRequest(fields, previous: nil)
    }

    /// Exchanges the refresh token for a new access token. Keeps the old refresh token when the provider doesn't rotate it
    /// (Google); TikTok may return a new one, which must replace the old.
    public func refresh(_ token: OAuthToken) async throws -> OAuthToken {
        guard let refreshToken = token.refreshToken else { throw OAuthError.noRefreshToken }
        var fields = [("grant_type", "refresh_token"), ("refresh_token", refreshToken), (config.clientIDParamName, config.clientID)]
        if let secret = config.clientSecret, !secret.isEmpty { fields.append(("client_secret", secret)) }
        return try await tokenRequest(fields, previous: token)
    }

    // MARK: - Internals

    private func tokenRequest(_ fields: [(String, String)], previous: OAuthToken?) async throws -> OAuthToken {
        let body = HTTPClient.formBody(fields)
        let (data, response) = try await http.sendWithRetry(RetryPolicy(maxRetries: 2), body: body) {
            var request = URLRequest(url: config.tokenURL)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
            return request
        }
        return try Self.parseToken(data, status: response.statusCode, previous: previous)
    }

    static func parseToken(_ data: Data, status: Int, previous: OAuthToken?, now: Date = Date()) throws -> OAuthToken {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        // Both providers report failures as {"error": "...", "error_description": "..."} (TikTok sometimes with HTTP 200).
        if let error = json?["error"] as? String, json?["access_token"] == nil {
            throw OAuthError.tokenEndpoint(status: status, error: error, description: json?["error_description"] as? String)
        }
        guard (200..<300).contains(status) else {
            throw OAuthError.tokenEndpoint(status: status, error: "http_error", description: data.utf8Text.isEmpty ? nil : String(data.utf8Text.prefix(300)))
        }
        guard let json, let access = json["access_token"] as? String, !access.isEmpty else {
            throw OAuthError.invalidTokenResponse("no access_token")
        }
        let expiresIn = (json["expires_in"] as? NSNumber)?.doubleValue ?? (json["expires_in"] as? String).flatMap(Double.init)
        return OAuthToken(accessToken: access,
                          refreshToken: (json["refresh_token"] as? String) ?? previous?.refreshToken,
                          expiresAt: expiresIn.map { now.addingTimeInterval($0) },
                          scope: (json["scope"] as? String) ?? previous?.scope,
                          tokenType: (json["token_type"] as? String) ?? previous?.tokenType ?? "Bearer",
                          userID: (json["open_id"] as? String) ?? previous?.userID)
    }

    static func callbackOutcome(_ request: HTTPServerRequest, expectedState: String) -> Result<String, OAuthError> {
        // Check state first so a forged error redirect can't abort someone else's sign-in either.
        guard request.queryValue("state") == expectedState else { return .failure(.stateMismatch) }
        if let error = request.queryValue("error") {
            return .failure(.authorizationDenied(error: error, description: request.queryValue("error_description")))
        }
        guard let code = request.queryValue("code"), !code.isEmpty else { return .failure(.missingCode) }
        return .success(code)
    }

    static func page(title: String, message: String) -> String {
        func escape(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
        }
        return """
        <!doctype html><html><head><meta charset="utf-8"><title>\(escape(title))</title>
        <style>body{font:16px -apple-system,system-ui,sans-serif;display:flex;align-items:center;justify-content:center;\
        height:90vh;color:#222}div{text-align:center}h1{font-size:22px}</style></head>
        <body><div><h1>\(escape(title))</h1><p>\(escape(message))</p></div></body></html>
        """
    }
}

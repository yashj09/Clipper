import Foundation

/// Instagram API with Instagram Login ("Business Login for Instagram"): consent → code → short-lived token →
/// long-lived token (60 days) → periodic refresh.
///
/// Why there is no loopback server: Meta requires the redirect URI to be HTTPS and to exactly match one registered
/// in the app, so the `http://127.0.0.1:<port>` trick used for YouTube/TikTok does not work. Instead:
/// 1. `authorizeURL(state:)` is opened in the browser;
/// 2. after consent Instagram redirects to the registered HTTPS URI (e.g. `https://localhost:8443/` — nothing needs
///    to listen there; the browser shows an error page but the address bar holds `?code=…`);
/// 3. the user pastes that final URL; `connect(pastedRedirect:expectedState:)` extracts the code (valid 1 hour,
///    single use), exchanges it with the app secret, upgrades to a long-lived token, looks up the professional
///    account id and stores everything under `instagram.token`.
///
/// Alternative without OAuth: generate a token in the App Dashboard (Instagram → API setup with Instagram login →
/// Generate access tokens; already long-lived) and store it with `storeDashboardToken(_:)`.
///
/// Docs: https://developers.facebook.com/docs/instagram-platform/instagram-api-with-instagram-login/business-login
public struct InstagramAuth: Sendable {
    /// Permissions needed to publish Reels.
    public static let scopes = ["instagram_business_basic", "instagram_business_content_publish"]
    /// Refresh tokens older than this before publishing (they live 60 days; Meta requires ≥ 24 h age to refresh).
    public static let refreshAge: TimeInterval = 50 * 24 * 3600

    public let credentials: any CredentialStore
    public let endpoints: InstagramEndpoints
    let http: InstagramHTTP
    let now: @Sendable () -> Date

    public init(credentials: any CredentialStore, endpoints: InstagramEndpoints = InstagramEndpoints(),
                session: URLSession = URLSession(configuration: .ephemeral), now: @escaping @Sendable () -> Date = { Date() }) {
        self.credentials = credentials; self.endpoints = endpoints; http = InstagramHTTP(session: session); self.now = now
    }

    /// App id/secret/redirect URI from the store.
    public struct AppCredentials: Sendable, Equatable {
        public var appID: String
        public var appSecret: String
        public var redirectURI: String
    }

    public func appCredentials() throws -> AppCredentials {
        func required(_ key: String) throws -> String {
            guard let value = try credentials.string(key)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
                throw InstagramError.notConnected("set \(key) (see docs/publishing.md#instagram)")
            }
            return value
        }
        let redirect = try required(InstagramCredentialKeys.redirectURI)
        guard URL(string: redirect)?.scheme?.lowercased() == "https" else {
            throw InstagramError.notConnected("\(InstagramCredentialKeys.redirectURI) must be an https:// URL registered in the Meta app")
        }
        return AppCredentials(appID: try required(InstagramCredentialKeys.appID),
                              appSecret: try required(InstagramCredentialKeys.appSecret), redirectURI: redirect)
    }

    /// A random value to pass as `state` and check when the redirect comes back.
    public static func makeState() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
        return SigV4Signer.hex(bytes)
    }

    /// Consent-screen URL to open in the browser.
    public func authorizeURL(state: String) throws -> URL {
        let app = try appCredentials()
        var components = URLComponents(url: endpoints.authorize, resolvingAgainstBaseURL: false)!
        components.percentEncodedQuery = InstagramHTTP.formEncode([
            ("client_id", app.appID), ("redirect_uri", app.redirectURI), ("response_type", "code"),
            ("scope", Self.scopes.joined(separator: ",")), ("state", state), ("enable_fb_login", "0"),
        ])
        return components.url!
    }

    /// Extracts the authorization code from the pasted redirect URL (or a bare code). Strips the `#_` Instagram
    /// appends, reports `error_description` when consent was denied and checks `state` when one is expected.
    public static func authorizationCode(fromPasted pasted: String, expectedState: String?) throws -> String {
        let text = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw InstagramError.authorization("nothing was pasted") }
        guard text.contains("?") || text.contains("://") else {
            // A bare code.
            return text.hasSuffix("#_") ? String(text.dropLast(2)) : text
        }
        guard let components = URLComponents(string: text) else {
            throw InstagramError.authorization("that is not a URL")
        }
        let items = components.queryItems ?? []
        func item(_ name: String) -> String? { items.first { $0.name == name }?.value }
        if let error = item("error") {
            let why = item("error_description") ?? item("error_reason") ?? error
            throw InstagramError.authorization(why.replacingOccurrences(of: "+", with: " "))
        }
        if let expectedState, item("state") != expectedState {
            throw InstagramError.authorization("state mismatch — start the login again")
        }
        guard var code = item("code"), !code.isEmpty else {
            throw InstagramError.authorization("the URL has no ?code= parameter")
        }
        if code.hasSuffix("#_") { code.removeLast(2) }
        return code
    }

    /// Paste-the-redirect path: code → short-lived → long-lived → `/me` → stored token.
    @discardableResult
    public func connect(pastedRedirect: String, expectedState: String?) async throws -> InstagramToken {
        try await exchange(code: Self.authorizationCode(fromPasted: pastedRedirect, expectedState: expectedState))
    }

    /// Exchanges an authorization code (requires the app secret), upgrades to a long-lived token and stores it.
    @discardableResult
    public func exchange(code: String) async throws -> InstagramToken {
        let app = try appCredentials()
        let data = try await http.post(endpoints.api, path: "oauth/access_token", form: [
            ("client_id", app.appID), ("client_secret", app.appSecret), ("grant_type", "authorization_code"),
            ("redirect_uri", app.redirectURI), ("code", code),
        ])
        let short = try http.decode(ShortLivedTokenResponse.self, data, "token exchange")
        guard let shortToken = short.token else { throw InstagramError.malformedResponse("token exchange returned no token") }
        if let granted = short.permissions,
           !granted.contains("instagram_business_content_publish") {
            throw InstagramError.authorization("the content publishing permission was not granted")
        }
        let longData = try await http.get(endpoints.graph, path: "access_token", query: [
            ("grant_type", "ig_exchange_token"), ("client_secret", app.appSecret), ("access_token", shortToken),
        ])
        let long = try http.decode(LongLivedTokenResponse.self, longData, "long-lived token exchange")
        return try await storeToken(accessToken: long.access_token, expiresIn: long.expires_in)
    }

    /// Stores a long-lived token generated in the App Dashboard (looks up the account id via `/me`).
    @discardableResult
    public func storeDashboardToken(_ accessToken: String) async throws -> InstagramToken {
        try await storeToken(accessToken: accessToken.trimmingCharacters(in: .whitespacesAndNewlines),
                             expiresIn: 60 * 24 * 3600)
    }

    private func storeToken(accessToken: String, expiresIn: Int?) async throws -> InstagramToken {
        let issued = now()
        let me = try await self.me(accessToken)
        let token = InstagramToken(userID: me.userID, username: me.username, accessToken: accessToken, issuedAt: issued,
                                   expiresAt: expiresIn.map { issued.addingTimeInterval(TimeInterval($0)) })
        try credentials.encode(token, for: InstagramCredentialKeys.token)
        return token
    }

    private func me(_ accessToken: String) async throws -> (userID: String, username: String?) {
        let data = try await http.get(endpoints.graph, path: "\(endpoints.version)/me", query: [
            ("fields", "user_id,username"), ("access_token", accessToken),
        ])
        let me = try http.decode(MeResponse.self, data, "/me")
        guard let id = me.user_id?.value ?? me.id?.value else { throw InstagramError.malformedResponse("/me has no user_id") }
        return (id, me.username)
    }

    public func storedToken() throws -> InstagramToken? {
        try credentials.decode(InstagramToken.self, InstagramCredentialKeys.token)
    }

    public func disconnect() throws { try credentials.set(nil, for: InstagramCredentialKeys.token) }

    /// The stored token, refreshed first when it is older than `refreshAge`. A failed refresh of a token that is
    /// still valid is not fatal: the old token is returned with the failure as `refreshWarning`.
    public func validToken() async throws -> (token: InstagramToken, refreshWarning: String?) {
        guard let token = try storedToken() else {
            throw InstagramError.notConnected("no token stored under \(InstagramCredentialKeys.token) — log in first")
        }
        let current = now()
        if token.isExpired(at: current) {
            throw InstagramError.notConnected("the access token expired on \(token.expiresAt!.formatted()) — log in again")
        }
        guard current.timeIntervalSince(token.issuedAt) >= Self.refreshAge else { return (token, nil) }
        do {
            return (try await refresh(token), nil)
        } catch {
            return (token, "token refresh failed: \(error.localizedDescription)")
        }
    }

    /// `GET /refresh_access_token?grant_type=ig_refresh_token` (token must be ≥ 24 h old and unexpired).
    @discardableResult
    public func refresh(_ token: InstagramToken) async throws -> InstagramToken {
        let data = try await http.get(endpoints.graph, path: "refresh_access_token", query: [
            ("grant_type", "ig_refresh_token"), ("access_token", token.accessToken),
        ])
        let response = try http.decode(LongLivedTokenResponse.self, data, "token refresh")
        let issued = now()
        var refreshed = token
        refreshed.accessToken = response.access_token
        refreshed.issuedAt = issued
        refreshed.expiresAt = response.expires_in.map { issued.addingTimeInterval(TimeInterval($0)) }
        try credentials.encode(refreshed, for: InstagramCredentialKeys.token)
        return refreshed
    }

    // MARK: Wire types

    /// Documented as either flat or wrapped in `data: [ … ]`; `permissions` as a comma string or an array.
    struct ShortLivedTokenResponse: Decodable {
        var token: String?
        var userID: String?
        var permissions: [String]?

        private struct Entry: Decodable {
            var access_token: String?
            var user_id: InstagramFlexibleID?
            var permissions: Permissions?
        }
        private struct Permissions: Decodable {
            var list: [String]
            init(from decoder: any Decoder) throws {
                let c = try decoder.singleValueContainer()
                if let s = try? c.decode(String.self) { list = s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
                else { list = try c.decode([String].self) }
            }
        }
        private struct Wrapped: Decodable { var data: [Entry]? }

        init(from decoder: any Decoder) throws {
            let entry: Entry
            if let wrapped = (try? Wrapped(from: decoder))?.data?.first { entry = wrapped } else { entry = try Entry(from: decoder) }
            token = entry.access_token; userID = entry.user_id?.value; permissions = entry.permissions?.list
        }
    }

    struct LongLivedTokenResponse: Decodable {
        var access_token: String
        var token_type: String?
        var expires_in: Int?
    }

    struct MeResponse: Decodable {
        var user_id: InstagramFlexibleID?
        var id: InstagramFlexibleID?
        var username: String?
    }
}

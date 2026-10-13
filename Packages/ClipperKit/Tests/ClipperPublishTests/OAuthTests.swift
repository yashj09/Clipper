@testable import ClipperPublish
import Foundation
import Testing

/// A mock authorization server: `/authorize` validates the request and 302-redirects to the loopback redirect URI (like
/// the provider would after consent); `/token` checks the PKCE verifier against the challenge and issues tokens.
final class MockAuthServer: Sendable {
    struct State: Sendable {
        var authorizeQuery: [String: String] = [:]
        var tokenRequests: [[String: String]] = []
        var refreshCount = 0
    }

    enum Callback: Sendable { case normal, wrongState, denied }

    let mock: MockServer
    let state: Box<State>
    let method: PKCEMethod
    let clientIDParam: String

    init(method: PKCEMethod = .s256, clientIDParam: String = "client_id", callback: Callback = .normal,
         rotateRefreshToken: Bool = false) async throws {
        let state = Box(State())
        self.state = state
        self.method = method
        self.clientIDParam = clientIDParam
        mock = try await MockServer { request in
            switch (request.method, request.path) {
            case ("GET", "/authorize"):
                let query = Dictionary(request.query.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { $1 })
                state.update { $0.authorizeQuery = query }
                guard let redirect = query["redirect_uri"], var components = URLComponents(string: redirect) else {
                    return HTTPServerResponse(status: 400)
                }
                switch callback {
                case .normal: components.queryItems = [.init(name: "code", value: "auth-code+/="), .init(name: "state", value: query["state"])]
                case .wrongState: components.queryItems = [.init(name: "code", value: "auth-code"), .init(name: "state", value: "forged")]
                case .denied: components.queryItems = [.init(name: "error", value: "access_denied"),
                                                       .init(name: "error_description", value: "User cancelled"),
                                                       .init(name: "state", value: query["state"])]
                }
                return HTTPServerResponse(status: 302, headers: [("Location", components.url!.absoluteString)])
            case ("POST", "/token"):
                let fields = formFields(request.body)
                let recorded = state.update { s -> [String: String] in s.tokenRequests.append(fields); return s.authorizeQuery }
                guard fields[clientIDParam] == "my-client", fields["client_secret"] == "my-secret" else {
                    return .json(["error": "invalid_client"], status: 401)
                }
                switch fields["grant_type"] {
                case "authorization_code":
                    guard fields["code"] == "auth-code+/=", fields["redirect_uri"] == recorded["redirect_uri"],
                          let verifier = fields["code_verifier"],
                          PKCE.challenge(for: verifier, method: method) == recorded["code_challenge"] else {
                        return .json(["error": "invalid_grant", "error_description": "PKCE or code mismatch"], status: 400)
                    }
                    return .json(["access_token": "access-1", "refresh_token": "refresh-1", "expires_in": 3600,
                                  "scope": recorded["scope"] ?? "", "token_type": "Bearer", "open_id": "user-1"])
                case "refresh_token":
                    let count = state.update { s -> Int in s.refreshCount += 1; return s.refreshCount }
                    guard fields["refresh_token"]?.hasPrefix("refresh-") == true else {
                        return .json(["error": "invalid_grant"], status: 400)
                    }
                    var body: [String: Any] = ["access_token": "access-refreshed-\(count)", "expires_in": 3600, "token_type": "Bearer"]
                    if rotateRefreshToken { body["refresh_token"] = "refresh-rotated-\(count)" }
                    return .json(body)
                default:
                    return .json(["error": "unsupported_grant_type"], status: 400)
                }
            default:
                return HTTPServerResponse(status: 404)
            }
        }
    }

    func config(scopes: [String] = ["a.scope", "b.scope"], separator: String = " ", redirectPath: String = "/callback") -> OAuthConfig {
        OAuthConfig(authorizeURL: mock.url("/authorize"), tokenURL: mock.url("/token"), clientID: "my-client",
                    clientSecret: "my-secret", scopes: scopes, scopeSeparator: separator,
                    extraAuthParams: ["access_type": "offline"], pkceMethod: method, clientIDParamName: clientIDParam,
                    redirectPath: redirectPath)
    }
}

/// Plays the browser: follows the authorize URL (302 → loopback callback) and keeps the final page.
final class FakeBrowser: Sendable {
    let page = Box<Task<(Int, String), Error>?>(nil)
    let openedURL = Box<URL?>(nil)

    var open: @Sendable (URL) -> Void {
        { [self] url in
            openedURL.update { $0 = url }
            page.update { $0 = Task {
                let (data, response) = try await URLSession.shared.data(from: url)
                return ((response as? HTTPURLResponse)?.statusCode ?? 0, String(decoding: data, as: UTF8.self))
            } }
        }
    }

    func finalPage() async throws -> (Int, String) {
        guard let task = page.value else { throw CancellationError() }
        return try await task.value
    }
}

@Suite struct OAuthTests {
    @Test func loopbackFlowEndToEndWithS256() async throws {
        let auth = try await MockAuthServer()
        defer { auth.mock.stop() }
        let browser = FakeBrowser()
        let client = OAuthClient(config: auth.config())

        let token = try await client.authorize(timeout: .seconds(20), open: browser.open)

        #expect(token.accessToken == "access-1")
        #expect(token.refreshToken == "refresh-1")
        #expect(token.userID == "user-1")
        #expect(token.scope == "a.scope b.scope")
        let expiresIn = try #require(token.expiresAt).timeIntervalSinceNow
        #expect(expiresIn > 3500 && expiresIn <= 3600)

        let query = auth.state.value.authorizeQuery
        #expect(query["client_id"] == "my-client")
        #expect(query["response_type"] == "code")
        #expect(query["scope"] == "a.scope b.scope")
        #expect(query["code_challenge_method"] == "S256")
        #expect(query["code_challenge"]?.count == 43)
        #expect(query["access_type"] == "offline")
        #expect((query["state"]?.count ?? 0) >= 32)
        let redirect = try #require(query["redirect_uri"].flatMap(URL.init(string:)))
        #expect(redirect.scheme == "http" && redirect.host == "127.0.0.1" && redirect.path == "/callback")
        #expect((redirect.port ?? 0) > 0)

        let (status, html) = try await browser.finalPage()
        #expect(status == 200)
        #expect(html.contains("You can close this window"))
    }

    @Test func tiktokVariantUsesClientKeyCommaScopesAndHexChallenge() async throws {
        let auth = try await MockAuthServer(method: .tiktokHexS256, clientIDParam: "client_key")
        defer { auth.mock.stop() }
        let browser = FakeBrowser()
        let client = OAuthClient(config: auth.config(scopes: ["user.info.basic", "video.upload"], separator: ",",
                                                     redirectPath: "/callback/"))
        let token = try await client.authorize(timeout: .seconds(20), open: browser.open)
        #expect(token.accessToken == "access-1")
        let query = auth.state.value.authorizeQuery
        #expect(query["client_key"] == "my-client")
        #expect(query["client_id"] == nil)
        #expect(query["scope"] == "user.info.basic,video.upload")
        #expect(query["code_challenge"]?.count == 64)   // hex SHA-256
        #expect(query["code_challenge"]?.allSatisfy(\.isHexDigit) == true)
        #expect(query["redirect_uri"]?.hasSuffix("/callback/") == true)
        #expect(auth.state.value.tokenRequests.first?["client_key"] == "my-client")
    }

    @Test func stateMismatchIsRejected() async throws {
        let auth = try await MockAuthServer(callback: .wrongState)
        defer { auth.mock.stop() }
        let browser = FakeBrowser()
        let client = OAuthClient(config: auth.config())
        // A forged redirect gets an error page but doesn't settle the sign-in: the flow keeps waiting (here: times out).
        await #expect(throws: OAuthError.timedOut) {
            _ = try await client.authorize(timeout: .seconds(1), open: browser.open)
        }
        #expect(auth.state.value.tokenRequests.isEmpty)   // no code exchange happened
        let (status, html) = try await browser.finalPage()
        #expect(status == 400)
        #expect(html.contains("state mismatch"))
    }

    @Test func strayCallbackDoesNotAbortSignIn() async throws {
        let auth = try await MockAuthServer()
        defer { auth.mock.stop() }
        let browser = FakeBrowser()
        let stray = Box<Int>(0)
        let client = OAuthClient(config: auth.config())
        // Before the real redirect arrives, something else hits the callback (a stale tab, a scanner).
        let token = try await client.authorize(timeout: .seconds(20)) { url in
            let redirect = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "redirect_uri" }?.value
            Task {
                if let redirect, let strayURL = URL(string: redirect + "?code=evil&state=someone-else"),
                   let (_, response) = try? await URLSession.shared.data(from: strayURL) {
                    stray.update { $0 = (response as? HTTPURLResponse)?.statusCode ?? 0 }
                }
                browser.open(url)
            }
        }
        #expect(stray.value == 400)
        #expect(token.accessToken == "access-1")
        #expect(auth.state.value.tokenRequests.count == 1)
    }

    @Test func providerErrorIsReported() async throws {
        let auth = try await MockAuthServer(callback: .denied)
        defer { auth.mock.stop() }
        let client = OAuthClient(config: auth.config())
        await #expect(throws: OAuthError.authorizationDenied(error: "access_denied", description: "User cancelled")) {
            _ = try await client.authorize(timeout: .seconds(20), open: FakeBrowser().open)
        }
    }

    @Test func timesOutWhenTheBrowserNeverReturns() async throws {
        let client = OAuthClient(config: OAuthConfig(authorizeURL: URL(string: "http://127.0.0.1:9/authorize")!,
                                                     tokenURL: URL(string: "http://127.0.0.1:9/token")!,
                                                     clientID: "x", scopes: []))
        let opened = Box<URL?>(nil)
        await #expect(throws: OAuthError.timedOut) {
            _ = try await client.authorize(timeout: .milliseconds(200)) { url in opened.update { $0 = url } }
        }
        #expect(opened.value != nil)
    }

    @Test func cancellationStopsWaiting() async throws {
        let client = OAuthClient(config: OAuthConfig(authorizeURL: URL(string: "http://127.0.0.1:9/authorize")!,
                                                     tokenURL: URL(string: "http://127.0.0.1:9/token")!,
                                                     clientID: "x", scopes: []))
        let task = Task { try await client.authorize(timeout: .seconds(60)) { _ in } }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        let start = ContinuousClock.now
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(ContinuousClock.now - start < .seconds(5))
    }

    @Test func refreshKeepsOrRotatesRefreshToken() async throws {
        let plain = try await MockAuthServer()
        defer { plain.mock.stop() }
        let old = OAuthToken(accessToken: "old", refreshToken: "refresh-1", expiresAt: Date(), scope: "a.scope")
        let refreshed = try await OAuthClient(config: plain.config()).refresh(old)
        #expect(refreshed.accessToken == "access-refreshed-1")
        #expect(refreshed.refreshToken == "refresh-1")   // Google: not rotated, keep the old one
        #expect(refreshed.scope == "a.scope")
        #expect(plain.state.value.tokenRequests.last?["grant_type"] == "refresh_token")

        let rotating = try await MockAuthServer(rotateRefreshToken: true)
        defer { rotating.mock.stop() }
        let rotated = try await OAuthClient(config: rotating.config()).refresh(old)
        #expect(rotated.refreshToken == "refresh-rotated-1")   // TikTok: must use the new one

        await #expect(throws: OAuthError.noRefreshToken) {
            _ = try await OAuthClient(config: plain.config()).refresh(OAuthToken(accessToken: "x"))
        }
    }

    @Test func tokenEndpointErrorsAreParsed() async throws {
        let auth = try await MockAuthServer()
        defer { auth.mock.stop() }
        var config = auth.config()
        config.clientSecret = "wrong"
        await #expect(throws: OAuthError.tokenEndpoint(status: 401, error: "invalid_client", description: nil)) {
            _ = try await OAuthClient(config: config).refresh(OAuthToken(accessToken: "a", refreshToken: "refresh-1"))
        }
        // TikTok-style error with HTTP 200.
        let body = Data(#"{"error":"invalid_request","error_description":"Redirect_uri is not matched","log_id":"1"}"#.utf8)
        #expect(throws: OAuthError.tokenEndpoint(status: 200, error: "invalid_request", description: "Redirect_uri is not matched")) {
            _ = try OAuthClient.parseToken(body, status: 200, previous: nil)
        }
    }

    @Test func tokenManagerRefreshesWithinSixtySecondsOfExpiry() async throws {
        let auth = try await MockAuthServer(rotateRefreshToken: true)
        defer { auth.mock.stop() }
        let store = InMemoryCredentialStore()
        let manager = TokenManager(client: OAuthClient(config: auth.config()), store: store, key: "youtube.token")
        #expect(try await manager.validToken() == nil)
        #expect(!manager.hasStoredToken())

        // Valid for 2 more minutes: used as is.
        try await manager.save(OAuthToken(accessToken: "fresh", refreshToken: "refresh-1", expiresAt: Date().addingTimeInterval(120)))
        #expect(try await manager.validToken()?.accessToken == "fresh")
        #expect(auth.state.value.refreshCount == 0)

        // Expires in 30 s: refreshed once (concurrent callers share the refresh) and saved.
        try await manager.save(OAuthToken(accessToken: "stale", refreshToken: "refresh-1", expiresAt: Date().addingTimeInterval(30)))
        async let a = manager.validToken()
        async let b = manager.validToken()
        let (first, second) = try await (a, b)
        #expect(first?.accessToken == "access-refreshed-1")
        #expect(second?.accessToken == "access-refreshed-1")
        #expect(auth.state.value.refreshCount == 1)
        let saved = try store.decode(OAuthToken.self, "youtube.token")
        #expect(saved?.accessToken == "access-refreshed-1")
        #expect(saved?.refreshToken == "refresh-rotated-1")
    }
}

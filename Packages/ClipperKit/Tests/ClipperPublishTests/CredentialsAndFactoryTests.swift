@testable import ClipperPublish
import Foundation
import Testing

@Suite struct KeychainTests {
    @Test func roundTripUpdateAndDelete() throws {
        // A unique service so the real "dev.yashjain.clipper.publish" items are never touched.
        let store = KeychainCredentialStore(service: "dev.yashjain.clipper.publish.tests.\(UUID().uuidString)")
        defer { try? store.removeAll() }

        #expect(try store.get("youtube.client_id") == nil)
        try store.setString("first", for: "youtube.client_id")
        #expect(try store.string("youtube.client_id") == "first")
        try store.setString("second", for: "youtube.client_id")             // update in place
        #expect(try store.string("youtube.client_id") == "second")

        let token = OAuthToken(accessToken: "a", refreshToken: "r", expiresAt: Date(timeIntervalSince1970: 1_800_000_000),
                               scope: "s", userID: "u")
        try store.encode(token, for: "youtube.token")
        #expect(try store.decode(OAuthToken.self, "youtube.token") == token)

        let binary = Data((0...255).map(UInt8.init))
        try store.set(binary, for: "binary")
        #expect(try store.get("binary") == binary)

        try store.set(nil, for: "youtube.client_id")                         // delete
        #expect(try store.get("youtube.client_id") == nil)
        try store.set(nil, for: "youtube.client_id")                         // deleting a missing item is fine
        #expect(try store.decode(OAuthToken.self, "youtube.token") == token)  // other keys untouched

        try store.removeAll()
        #expect(try store.get("youtube.token") == nil)
    }
}

@Suite struct FactoryTests {
    @Test func missingKeysPerPlatform() throws {
        let store = InMemoryCredentialStore()
        let credentials = PlatformCredentials(store: store)
        #expect(try credentials.missingKeys(for: .youtube).map(\.key) == ["youtube.client_id", "youtube.client_secret"])
        #expect(try credentials.missingKeys(for: .tiktok).map(\.key) == ["tiktok.client_key", "tiktok.client_secret"])
        #expect(try credentials.missingKeys(for: .instagram).map(\.key) == ["instagram.app_id", "instagram.app_secret", "instagram.redirect_uri"])

        try credentials.setValue("  id-123  ", for: PlatformCredentials.fields(for: .youtube)[0])
        try store.setString("   ", for: "youtube.client_secret")                // blank counts as missing
        #expect(try credentials.missingKeys(for: .youtube).map(\.key) == ["youtube.client_secret"])
        #expect(try store.string("youtube.client_id") == "id-123")
        #expect(throws: PublishError.missingCredentials(.youtube, ["youtube.client_secret"])) {
            _ = try PublisherFactory.publisher(for: .youtube, store: store)
        }
        // Instagram has its own token flow: a publisher exists without credentials but isn't connected.
        #expect(try PublisherFactory.publisher(for: .instagram, store: store).platform == .instagram)
    }

    @Test func oauthConfigsMatchProviderDocs() throws {
        let store = InMemoryCredentialStore()
        for (key, value) in ["youtube.client_id": "gid", "youtube.client_secret": "gsecret",
                             "tiktok.client_key": "tkey", "tiktok.client_secret": "tsecret"] {
            try store.setString(value, for: key)
        }
        let google = try PublisherFactory.oauthConfig(for: .youtube, store: store)
        #expect(google.authorizeURL.absoluteString == "https://accounts.google.com/o/oauth2/v2/auth")
        #expect(google.tokenURL.absoluteString == "https://oauth2.googleapis.com/token")
        #expect(google.clientIDParamName == "client_id" && google.pkceMethod == .s256 && google.scopeSeparator == " ")
        #expect(google.scopes == ["https://www.googleapis.com/auth/youtube.upload",
                                  "https://www.googleapis.com/auth/youtube.force-ssl"])
        #expect(google.extraAuthParams["access_type"] == "offline")

        let tiktok = try PublisherFactory.oauthConfig(for: .tiktok, store: store)
        #expect(tiktok.authorizeURL.absoluteString == "https://www.tiktok.com/v2/auth/authorize/")
        #expect(tiktok.tokenURL.absoluteString == "https://open.tiktokapis.com/v2/oauth/token/")
        #expect(tiktok.clientIDParamName == "client_key" && tiktok.pkceMethod == .tiktokHexS256 && tiktok.scopeSeparator == ",")
        #expect(tiktok.scopes == ["user.info.basic", "video.upload"])
        #expect(tiktok.redirectPath == "/callback/")

        // Building the URL must not touch the network.
        let pkce = PKCE(verifier: PKCETests.rfcVerifier, method: .tiktokHexS256)
        let url = OAuthClient(config: tiktok).authorizationURL(redirectURI: "http://127.0.0.1:5555/callback/", state: "st", pkce: pkce)
        let items = Dictionary(URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value!) },
                               uniquingKeysWith: { $1 })
        #expect(items == ["client_key": "tkey", "response_type": "code", "redirect_uri": "http://127.0.0.1:5555/callback/",
                          "scope": "user.info.basic,video.upload", "state": "st", "code_challenge": pkce.challenge,
                          "code_challenge_method": "S256"])

        #expect(try PublisherFactory.publisher(for: .youtube, store: store) is YouTubePublisher)
        #expect(try PublisherFactory.publisher(for: .tiktok, store: store) is TikTokPublisher)
    }

    @Test func connectStoresTokenAndDisconnectRemovesIt() async throws {
        let auth = try await MockAuthServer(method: .tiktokHexS256, clientIDParam: "client_key")
        defer { auth.mock.stop() }
        let store = InMemoryCredentialStore()
        try store.setString("my-client", for: "tiktok.client_key")
        try store.setString("my-secret", for: "tiktok.client_secret")
        var endpoints = PublishEndpoints()
        endpoints.tiktokAuthorize = auth.mock.url("/authorize")
        endpoints.tiktokToken = auth.mock.url("/token")
        endpoints.tiktokAPIBase = auth.mock.baseURL

        let publisher = try PublisherFactory.publisher(for: .tiktok, store: store, endpoints: endpoints)
        #expect(await !publisher.isConnected())
        let token = try await PublisherFactory.connect(platform: .tiktok, store: store, endpoints: endpoints,
                                                       timeout: .seconds(20), open: FakeBrowser().open)
        #expect(token.accessToken == "access-1")
        #expect(try store.decode(OAuthToken.self, "tiktok.token") == token)
        #expect(await publisher.isConnected())
        #expect(PlatformCredentials(store: store).hasToken(for: .tiktok))

        try PublisherFactory.disconnect(platform: .tiktok, store: store)
        #expect(await !publisher.isConnected())
        #expect(try store.string("tiktok.client_key") == "my-client")
        try PublisherFactory.disconnect(platform: .tiktok, store: store, forgetAppCredentials: true)
        #expect(try PlatformCredentials(store: store).missingKeys(for: .tiktok).count == 2)
    }

    @Test func setupInstructionsNameRedirectURIsAndScopes() {
        let youtube = PublisherFactory.setupInstructions(for: .youtube)
        #expect(youtube.contains("Desktop app"))
        #expect(youtube.contains("http://127.0.0.1"))
        #expect(youtube.contains("youtube.upload") && youtube.contains("youtube.force-ssl"))
        let tiktok = PublisherFactory.setupInstructions(for: .tiktok)
        #expect(tiktok.contains("http://127.0.0.1:*/callback/"))
        #expect(tiktok.contains("video.upload"))
        let instagram = PublisherFactory.setupInstructions(for: .instagram)
        #expect(instagram.contains("https") && instagram.contains("R2") && instagram.contains("public"))
    }
}

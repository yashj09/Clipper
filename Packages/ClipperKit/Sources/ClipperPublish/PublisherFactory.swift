import Foundation

/// One secret the user supplies for a platform ("bring your own keys").
public struct CredentialField: Sendable, Hashable {
    /// CredentialStore key, e.g. "youtube.client_id".
    public var key: String
    /// What the developer console calls it, e.g. "Client ID".
    public var label: String
    public var isSecret: Bool
}

/// Which keys each platform needs, and whether they're present.
public struct PlatformCredentials: Sendable {
    public let store: any CredentialStore
    public init(store: any CredentialStore) { self.store = store }

    public static func fields(for platform: Platform) -> [CredentialField] {
        switch platform {
        case .youtube:
            [CredentialField(key: "youtube.client_id", label: "Client ID", isSecret: false),
             CredentialField(key: "youtube.client_secret", label: "Client secret", isSecret: true)]
        case .tiktok:
            [CredentialField(key: "tiktok.client_key", label: "Client key", isSecret: false),
             CredentialField(key: "tiktok.client_secret", label: "Client secret", isSecret: true)]
        case .instagram:
            []
        }
    }

    /// Key under which the OAuth token is stored.
    public static func tokenKey(for platform: Platform) -> String { "\(platform.rawValue).token" }

    /// App credentials that are not yet stored (empty strings count as missing).
    public func missingKeys(for platform: Platform) throws -> [CredentialField] {
        try Self.fields(for: platform).filter { field in
            (try store.string(field.key)).map { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? true
        }
    }

    public func value(_ field: CredentialField) throws -> String? {
        try store.string(field.key)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func setValue(_ value: String?, for field: CredentialField) throws {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        try store.setString(trimmed?.isEmpty == true ? nil : trimmed, for: field.key)
    }

    public func hasToken(for platform: Platform) -> Bool { ((try? store.get(Self.tokenKey(for: platform))) ?? nil) != nil }
}

/// Production endpoints; tests substitute mock-server URLs.
public struct PublishEndpoints: Sendable, Equatable {
    public var googleAuthorize = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    public var googleToken = URL(string: "https://oauth2.googleapis.com/token")!
    public var youtubeUploadBase = YouTubePublisher.defaultUploadBaseURL
    public var tiktokAuthorize = URL(string: "https://www.tiktok.com/v2/auth/authorize/")!
    public var tiktokToken = URL(string: "https://open.tiktokapis.com/v2/oauth/token/")!
    public var tiktokAPIBase = TikTokPublisher.defaultAPIBaseURL
    public init() {}
    public static let production = PublishEndpoints()
}

/// Builds OAuth configurations and publishers from stored credentials; connects and disconnects accounts.
public enum PublisherFactory {
    /// Redirect path for TikTok; the registered URI must be exactly `http://127.0.0.1:*/callback/`.
    public static let tiktokRedirectPath = "/callback/"
    public static let tiktokRegisteredRedirectURI = "http://127.0.0.1:*/callback/"

    public static func oauthConfig(for platform: Platform, store: any CredentialStore,
                                   endpoints: PublishEndpoints = .production) throws -> OAuthConfig {
        let credentials = PlatformCredentials(store: store)
        let missing = try credentials.missingKeys(for: platform)
        guard missing.isEmpty else { throw PublishError.missingCredentials(platform, missing.map(\.key)) }
        let fields = PlatformCredentials.fields(for: platform)
        switch platform {
        case .youtube:
            // https://developers.google.com/identity/protocols/oauth2/native-app — loopback http://127.0.0.1:<port>,
            // S256 PKCE, scopes space-separated. access_type=offline + prompt=consent so reconnecting always yields a
            // refresh token.
            return OAuthConfig(authorizeURL: endpoints.googleAuthorize, tokenURL: endpoints.googleToken,
                               clientID: try credentials.value(fields[0])!, clientSecret: try credentials.value(fields[1]),
                               scopes: YouTubePublisher.scopes, scopeSeparator: " ",
                               extraAuthParams: ["access_type": "offline", "prompt": "consent"],
                               pkceMethod: .s256, clientIDParamName: "client_id", redirectPath: "/callback")
        case .tiktok:
            // https://developers.tiktok.com/doc/login-kit-desktop — client_key, comma-separated scopes, hex-SHA256 PKCE.
            return OAuthConfig(authorizeURL: endpoints.tiktokAuthorize, tokenURL: endpoints.tiktokToken,
                               clientID: try credentials.value(fields[0])!, clientSecret: try credentials.value(fields[1]),
                               scopes: TikTokPublisher.scopes, scopeSeparator: ",", extraAuthParams: [:],
                               pkceMethod: .tiktokHexS256, clientIDParamName: "client_key",
                               redirectPath: tiktokRedirectPath)
        case .instagram:
            throw PublishError.unsupportedPlatform(.instagram)
        }
    }

    public static func tokenManager(for platform: Platform, store: any CredentialStore,
                                    endpoints: PublishEndpoints = .production, session: URLSession? = nil) throws -> TokenManager {
        let client = OAuthClient(config: try oauthConfig(for: platform, store: store, endpoints: endpoints), session: session)
        return TokenManager(client: client, store: store, key: PlatformCredentials.tokenKey(for: platform))
    }

    /// A publisher for `platform`. Throws when app credentials are missing; `isConnected()` tells whether an account
    /// is connected.
    public static func publisher(for platform: Platform, store: any CredentialStore,
                                 endpoints: PublishEndpoints = .production, session: URLSession? = nil) throws -> any Publisher {
        let tokens = try tokenManager(for: platform, store: store, endpoints: endpoints, session: session)
        switch platform {
        case .youtube: return YouTubePublisher(tokens: tokens, uploadBaseURL: endpoints.youtubeUploadBase, session: session)
        case .tiktok: return TikTokPublisher(tokens: tokens, apiBaseURL: endpoints.tiktokAPIBase, session: session)
        case .instagram: throw PublishError.unsupportedPlatform(.instagram)
        }
    }

    /// Runs the browser sign-in (`open` should open the URL in the default browser) and stores the token.
    @discardableResult
    public static func connect(platform: Platform, store: any CredentialStore, endpoints: PublishEndpoints = .production,
                               session: URLSession? = nil, timeout: Duration = .seconds(300),
                               open: @Sendable (URL) -> Void) async throws -> OAuthToken {
        let client = OAuthClient(config: try oauthConfig(for: platform, store: store, endpoints: endpoints), session: session)
        let token = try await client.authorize(timeout: timeout, open: open)
        try store.encode(token, for: PlatformCredentials.tokenKey(for: platform))
        return token
    }

    /// Forgets the account's token (locally; revoke access in the platform's account settings). With
    /// `forgetAppCredentials`, also deletes the client id/secret.
    public static func disconnect(platform: Platform, store: any CredentialStore, forgetAppCredentials: Bool = false) throws {
        try store.set(nil, for: PlatformCredentials.tokenKey(for: platform))
        if forgetAppCredentials {
            for field in PlatformCredentials.fields(for: platform) { try store.set(nil, for: field.key) }
        }
    }

    // MARK: - Setup instructions

    /// Step-by-step instructions the CLI/app show for creating the user's own developer app.
    public static func setupInstructions(for platform: Platform) -> String {
        switch platform {
        case .youtube:
            """
            YouTube uses your own Google Cloud project ("bring your own keys"):
            1. Open https://console.cloud.google.com/ and create a project (e.g. "Clipper").
            2. APIs & Services → Library → enable "YouTube Data API v3".
            3. Google Auth Platform (OAuth consent screen): user type External; under Audience add your Google account \
            as a test user; under Data access add the scopes
               https://www.googleapis.com/auth/youtube.upload
               https://www.googleapis.com/auth/youtube.force-ssl   (needed to upload captions)
            4. Clients → Create client → Application type "Desktop app". No redirect URI needs registering: desktop \
            clients accept the loopback address on any port, and Clipper listens on http://127.0.0.1:<random port>/callback.
            5. Copy the Client ID and Client secret into Clipper, then connect your YouTube account (a browser window opens).
            Notes:
            • Unverified/unaudited API projects have historically had uploads locked to private (Google's docs now say \
            this restriction no longer applies). If your uploads stay private, request YouTube's API compliance audit and \
            change visibility in YouTube Studio meanwhile.
            • Quota: uploads use their own bucket (100 per day); a caption upload costs 400 of the default 10,000 \
            daily units.
            • While the consent screen is in "Testing", Google expires refresh tokens after 7 days, so you'll need to \
            reconnect weekly (or publish the consent screen).
            """
        case .tiktok:
            """
            TikTok uses your own TikTok for Developers app ("bring your own keys"):
            1. Open https://developers.tiktok.com/ → Manage apps → Connect an app (platform: Desktop).
            2. Add the products "Login Kit" and "Content Posting API"; request the scopes user.info.basic and video.upload.
            3. Login Kit → Desktop redirect URI: register exactly
               \(tiktokRegisteredRedirectURI)
               (TikTok allows only localhost/127.0.0.1 with a port; "*" is the wildcard port. Clipper listens on a random port.)
            4. Until the app is approved, use the Sandbox tab and add your TikTok account as a target user.
            5. Copy the Client key and Client secret into Clipper, then connect your TikTok account (a browser window opens).
            Notes:
            • Clipper uploads drafts to your TikTok inbox; you finish the post (caption, sound, privacy) in the TikTok app.
            • Unaudited apps are limited: at most 5 pending inbox drafts per 24 hours, and direct posts are private-only \
            until TikTok's audit (2–6 weeks).
            • TikTok recommends keeping the client secret on a server; Clipper keeps it in your Mac's Keychain, which is \
            fine for personal use.
            """
        case .instagram:
            """
            Instagram publishing isn't supported yet: the Graph API needs the video at a public HTTPS URL, which needs a \
            server or bucket Clipper doesn't have.
            """
        }
    }
}

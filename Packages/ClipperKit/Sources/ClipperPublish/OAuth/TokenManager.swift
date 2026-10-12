import Foundation

/// Owns one platform's token in a CredentialStore: hands out a valid access token, refreshing it when it expires within
/// `refreshMargin` (60 s), and saving rotated tokens. Concurrent callers share a single in-flight refresh.
public actor TokenManager {
    public nonisolated let client: OAuthClient
    public nonisolated let store: any CredentialStore
    public nonisolated let key: String
    public nonisolated let refreshMargin: TimeInterval
    private let now: @Sendable () -> Date
    private var refreshing: Task<OAuthToken, Error>?

    public init(client: OAuthClient, store: any CredentialStore, key: String, refreshMargin: TimeInterval = 60,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.client = client; self.store = store; self.key = key; self.refreshMargin = refreshMargin; self.now = now
    }

    /// Whether a token is saved (no network, no refresh).
    public nonisolated func hasStoredToken() -> Bool { ((try? store.get(key)) ?? nil) != nil }

    public func storedToken() throws -> OAuthToken? { try store.decode(OAuthToken.self, key) }

    public func save(_ token: OAuthToken?) throws { try store.encode(token, for: key) }

    /// A token valid for at least `refreshMargin` seconds, refreshing (and saving) it if needed; nil when none is saved.
    /// Throws `OAuthError.noRefreshToken` when the saved token is expiring and has no refresh token.
    public func validToken() async throws -> OAuthToken? {
        guard let token = try storedToken() else { return nil }
        guard token.expires(within: refreshMargin, now: now()) else { return token }
        return try await refreshNow(token)
    }

    /// Forces a refresh (e.g. after a 401), returning the new token.
    public func refreshNow(_ token: OAuthToken? = nil) async throws -> OAuthToken {
        if let refreshing { return try await refreshing.value }
        guard let current = try token ?? storedToken() else { throw OAuthError.noRefreshToken }
        let client = client
        let task = Task { try await client.refresh(current) }
        refreshing = task
        defer { refreshing = nil }
        let fresh = try await task.value
        try save(fresh)
        return fresh
    }
}

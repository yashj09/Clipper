import Foundation

/// Secrets for publishing (client ids/secrets, tokens, storage keys). The real store is the macOS Keychain; tests use
/// the in-memory one. Keys are namespaced strings such as "youtube.client_id" or "youtube.token".
public protocol CredentialStore: Sendable {
    func get(_ key: String) throws -> Data?
    func set(_ value: Data?, for key: String) throws   // nil deletes
}

extension CredentialStore {
    public func string(_ key: String) throws -> String? { try get(key).map { String(decoding: $0, as: UTF8.self) } }
    public func setString(_ value: String?, for key: String) throws { try set(value.map { Data($0.utf8) }, for: key) }
    public func decode<T: Decodable>(_ type: T.Type, _ key: String) throws -> T? {
        try get(key).map { try JSONDecoder().decode(T.self, from: $0) }
    }
    public func encode<T: Encodable>(_ value: T?, for key: String) throws {
        try set(value.map { try JSONEncoder().encode($0) }, for: key)
    }
}

public final class InMemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data]
    public init(_ values: [String: Data] = [:]) { self.values = values }
    public func get(_ key: String) throws -> Data? { lock.withLock { values[key] } }
    public func set(_ value: Data?, for key: String) throws { lock.withLock { values[key] = value } }
}

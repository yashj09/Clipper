import Foundation
import Security

/// Publishing secrets in the user's login Keychain as generic-password items: service = `service`, account = key.
///
/// Uses the file-based login keychain (no keychain-access-group entitlement needed, so the unsigned CLI works too).
/// Items are readable without a prompt by the binary that created them; another binary (CLI vs. app) may trigger a
/// one-time "allow access" Keychain prompt.
public struct KeychainCredentialStore: CredentialStore {
    public static let defaultService = "dev.yashjain.clipper.publish"
    public let service: String

    public init(service: String = KeychainCredentialStore.defaultService) { self.service = service }

    public func get(_ key: String) throws -> Data? {
        var query = baseQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess: return result as? Data
        case errSecItemNotFound: return nil
        default: throw KeychainError(status: status, operation: "read \(key)")
        }
    }

    public func set(_ value: Data?, for key: String) throws {
        guard let value else {
            let status = SecItemDelete(baseQuery(key) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw KeychainError(status: status, operation: "delete \(key)")
            }
            return
        }
        let update: [String: Any] = [kSecValueData as String: value]
        let status = SecItemUpdate(baseQuery(key) as CFDictionary, update as CFDictionary)
        switch status {
        case errSecSuccess: return
        case errSecItemNotFound:
            var add = baseQuery(key)
            add[kSecValueData as String] = value
            add[kSecAttrLabel as String] = "Clipper publishing (\(key))"
            // No kSecAttrAccessible: the file-based login keychain ignores it (it applies to the data protection
            // keychain only); access is governed by the item's ACL (the creating binary) and the keychain's lock state.
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError(status: addStatus, operation: "add \(key)") }
        default:
            throw KeychainError(status: status, operation: "update \(key)")
        }
    }

    /// Deletes every item under this service (used by tests and "forget all").
    public func removeAll() throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status, operation: "delete all")
        }
    }

    private func baseQuery(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: key]
    }
}

public struct KeychainError: Error, Sendable, Equatable, LocalizedError {
    public var status: OSStatus
    public var operation: String
    public var errorDescription: String? {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        return "Keychain couldn't \(operation): \(message)"
    }
}

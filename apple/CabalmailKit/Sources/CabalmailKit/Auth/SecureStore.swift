import Foundation
import Synchronization
#if canImport(Security)
import Security
#endif

/// Minimal key/value store for secrets that the Apple client must persist
/// across launches — the Cognito tokens.
///
/// Extracted behind a protocol so unit tests can inject `InMemorySecureStore`
/// without linking the Security framework's kSecClass side effects into the
/// test process.
public protocol SecureStore: Sendable {
    func set(_ value: Data, forKey key: String) throws
    func get(_ key: String) throws -> Data?
    func remove(_ key: String) throws
}

public extension SecureStore {
    func setString(_ value: String, forKey key: String) throws {
        try set(Data(value.utf8), forKey: key)
    }

    func getString(_ key: String) throws -> String? {
        guard let data = try get(key) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// In-memory store used by tests. Thread-safe: the entries live in a `Mutex`.
public final class InMemorySecureStore: SecureStore {
    private let storage = Mutex<[String: Data]>([:])

    public init() {}

    public func set(_ value: Data, forKey key: String) throws {
        storage.withLock { $0[key] = value }
    }

    public func get(_ key: String) throws -> Data? {
        storage.withLock { $0[key] }
    }

    public func remove(_ key: String) throws {
        _ = storage.withLock { $0.removeValue(forKey: key) }
    }
}

#if canImport(Security)
/// Production Keychain-backed implementation. Uses the data-protection
/// keychain on iOS and on Release macOS builds; macOS DEBUG builds fall back
/// to the file-based login keychain, which needs no keychain-access-group
/// entitlement -- so a locally-run (ad-hoc / unsigned) dev build can store
/// credentials instead of failing with errSecMissingEntitlement (-34018).
/// Every OSStatus other than success (or not-found, where that means
/// absent) throws `CabalmailError.storage` with the status in its detail.
public struct KeychainSecureStore: SecureStore {
    public let service: String
    public let accessGroup: String?

    public init(service: String = "com.cabalmail.CabalmailKit", accessGroup: String? = nil) {
        self.service = service
        self.accessGroup = accessGroup
    }

    private func baseQuery(_ key: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        // iOS (all configs) and Release macOS use the data-protection keychain
        // -- which on macOS needs the keychain-access-group entitlement the
        // signed app declares. macOS DEBUG builds fall back to the file-based
        // login keychain so a locally-run dev build (often ad-hoc / unsigned,
        // hence without that entitlement) can still store credentials rather
        // than failing SecItemAdd with errSecMissingEntitlement (-34018).
        #if !(os(macOS) && DEBUG)
        query[kSecUseDataProtectionKeychain as String] = true
        #endif
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }

    public func set(_ value: Data, forKey key: String) throws {
        var query = baseQuery(key)
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            let attrs: [String: Any] = [kSecValueData as String: value]
            let update = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
            guard update == errSecSuccess else {
                throw CabalmailError.storage("Keychain update failed: \(update)")
            }
        case errSecItemNotFound:
            query[kSecValueData as String] = value
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let add = SecItemAdd(query as CFDictionary, nil)
            guard add == errSecSuccess else {
                throw CabalmailError.storage("Keychain add failed: \(add)")
            }
        default:
            throw CabalmailError.storage("Keychain query failed: \(status)")
        }
    }

    public func get(_ key: String) throws -> Data? {
        var query = baseQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:        return item as? Data
        case errSecItemNotFound:   return nil
        default:
            throw CabalmailError.storage("Keychain read failed: \(status)")
        }
    }

    public func remove(_ key: String) throws {
        let status = SecItemDelete(baseQuery(key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CabalmailError.storage("Keychain delete failed: \(status)")
        }
    }
}
#endif

/// Well-known keys used by the package. Kept in one place so sign-out can
/// clear them exhaustively.
public enum SecureStoreKey {
    public static let authTokens = "auth.tokens"
    /// No longer written; kept so stores from older builds can be scrubbed.
    public static let imapUsername = "imap.username"
    /// No longer written; kept so stores from older builds can be scrubbed.
    public static let imapPassword = "imap.password"
}

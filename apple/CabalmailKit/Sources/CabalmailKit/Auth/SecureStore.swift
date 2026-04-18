import Foundation
#if canImport(Security)
import Security
#endif

/// Minimal key/value store for secrets that the Apple client must persist
/// across launches — Cognito tokens and the IMAP/SMTP password.
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

/// In-memory store used by tests. Not thread-safe — tests drive it from a
/// single task, and `Sendable` conformance is satisfied by the reference
/// semantics of the underlying `NSMutableDictionary`.
public final class InMemorySecureStore: SecureStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Data] = [:]

    public init() {}

    public func set(_ value: Data, forKey key: String) throws {
        lock.lock(); defer { lock.unlock() }
        storage[key] = value
    }

    public func get(_ key: String) throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        return storage[key]
    }

    public func remove(_ key: String) throws {
        lock.lock(); defer { lock.unlock() }
        storage.removeValue(forKey: key)
    }
}

#if canImport(Security)
/// Production Keychain-backed implementation. Uses the data-protection
/// keychain on every Apple platform so iOS and macOS behave identically.
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
            kSecUseDataProtectionKeychain as String: true,
        ]
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
                throw CabalmailError.transport("Keychain update failed: \(update)")
            }
        case errSecItemNotFound:
            query[kSecValueData as String] = value
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let add = SecItemAdd(query as CFDictionary, nil)
            guard add == errSecSuccess else {
                throw CabalmailError.transport("Keychain add failed: \(add)")
            }
        default:
            throw CabalmailError.transport("Keychain query failed: \(status)")
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
            throw CabalmailError.transport("Keychain read failed: \(status)")
        }
    }

    public func remove(_ key: String) throws {
        let status = SecItemDelete(baseQuery(key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CabalmailError.transport("Keychain delete failed: \(status)")
        }
    }
}
#endif

/// Well-known keys used by the package. Kept in one place so sign-out can
/// clear them exhaustively.
public enum SecureStoreKey {
    public static let authTokens = "auth.tokens"
    public static let imapUsername = "imap.username"
    public static let imapPassword = "imap.password"
}

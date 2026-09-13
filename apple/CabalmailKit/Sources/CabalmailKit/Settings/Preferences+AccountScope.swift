import Foundation

extension Preferences {
    /// Stable per-account scope hash (FNV-1a 64 of the normalized control
    /// domain + username) that `activate(controlDomain:username:)` keys every
    /// stored value on. Hashing keeps usernames out of stored key names and
    /// the key length bounded regardless of username length. `nil` when
    /// either input is empty.
    static func scopeIdentifier(controlDomain: String, username: String) -> String? {
        let domain = controlDomain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let user = username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !domain.isEmpty, !user.isEmpty else { return nil }
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in "\(domain)|\(user)".utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(format: "%016llx", hash)
    }
}

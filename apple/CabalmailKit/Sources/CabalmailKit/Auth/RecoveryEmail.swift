import Foundation

/// The signed-in user's ways back in, from `GetUser`'s attributes: the
/// recovery email and whether it is verified, and whether the phone is
/// verified (`docs/auth.md`, "After sign-in" and "Recovery email").
public struct RecoveryContacts: Sendable, Equatable {
    /// Nil when the account has none.
    public let email: String?
    public let emailVerified: Bool
    public let phoneVerified: Bool

    public init(email: String?, emailVerified: Bool, phoneVerified: Bool) {
        self.email = email.flatMap { $0.isEmpty ? nil : $0 }
        self.emailVerified = emailVerified
        self.phoneVerified = phoneVerified
    }

    /// From a `GetUser` reply's `UserAttributes` (`[{Name, Value}]`).
    init(getUserReply reply: [String: Any]) {
        var attributes: [String: String] = [:]
        for attribute in reply["UserAttributes"] as? [[String: Any]] ?? [] {
            if let name = attribute["Name"] as? String, let value = attribute["Value"] as? String {
                attributes[name] = value
            }
        }
        self.init(
            email: attributes["email"],
            emailVerified: attributes["email_verified"] == "true",
            phoneVerified: attributes["phone_number_verified"] == "true"
        )
    }

    /// What to ask right after a sign-in, or nil for nothing (plan D5):
    /// to verify an email the user gave but never verified, whatever the
    /// phone says; to add one when there is none, unless the pool has SMS
    /// and the phone is verified, since the phone then recovers the
    /// account. The webmail asks the same (`App.jsx`, `finishLogin`).
    public func promptAfterSignIn(smsEnabled: Bool) -> RecoveryEmailPrompt? {
        if let email {
            return emailVerified ? nil : .verify(email)
        }
        return smsEnabled && phoneVerified ? nil : .add
    }
}

/// The recovery-email check's question (`RecoveryContacts.promptAfterSignIn`).
public enum RecoveryEmailPrompt: Sendable, Equatable {
    /// The account has no recovery email and nothing else recovers it.
    case add
    /// The account's recovery email is not verified yet.
    case verify(String)
}

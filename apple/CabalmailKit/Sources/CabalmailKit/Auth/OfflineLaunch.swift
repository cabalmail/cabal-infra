import Foundation

/// What launch-time restore may do without a network.
///
/// A cold launch with no connection used to land on the sign-in form even
/// though the mailbox, Outbox and feeds were all on disk: `config.json`
/// was never kept (`ConfigLoader` now takes a `ConfigurationCache`), and a
/// token refresh that couldn't reach Cognito was read as "signed out".
public enum OfflineLaunch {
    /// Validates the stored session the way restore needs it validated.
    ///
    /// A fresh ID token passes; an expired one is refreshed; a refresh
    /// Cognito refuses throws `.authExpired` (and announces it through the
    /// service's `SessionInvalidationMonitor`). A refresh that never reached
    /// Cognito says nothing about the session, so it passes too: the caller
    /// wires the session with the keychain tokens, and the first call made
    /// back online refreshes for real.
    public static func validateStoredSession(_ authService: any AuthService) async throws {
        do {
            _ = try await authService.currentIdToken()
        } catch let error as CabalmailError where error.isUnreachable {
            return
        }
    }
}

extension CabalmailError {
    /// The request never got an answer: no network, a dropped connection,
    /// or a timeout. Distinct from anything the server said.
    var isUnreachable: Bool {
        switch self {
        case .network, .transport:
            return true
        default:
            return false
        }
    }
}

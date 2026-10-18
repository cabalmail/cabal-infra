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
    /// back online refreshes for real. So does a refresh Cognito throttled or
    /// failed internally (#1828), which used to end the launch on the
    /// sign-in form with Cognito's error text, and so does an answer that
    /// doesn't parse as Cognito's at all (#1902).
    public static func validateStoredSession(_ authService: any AuthService) async throws {
        do {
            _ = try await authService.currentIdToken()
        } catch let error as CabalmailError
            where error.isUnreachable || error.isTransientRefusal || error.isUnreadableReply {
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

    /// Cognito answered but declined for now: it throttled the call or
    /// failed on its side. Like no answer at all, that says nothing about
    /// the session.
    var isTransientRefusal: Bool {
        guard case .server(let code, _) = self else { return false }
        return code == "TooManyRequestsException" || code == "InternalErrorException"
    }

    /// The answer didn't parse as Cognito's: an empty body, or an HTML page
    /// from something in the network path answering for it behind a 2xx
    /// (#1902). Cognito refuses a session with a non-2xx it names, so a
    /// reply this side can't read says nothing about the session either.
    var isUnreadableReply: Bool {
        guard case .decoding = self else { return false }
        return true
    }
}

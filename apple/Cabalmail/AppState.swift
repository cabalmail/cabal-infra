import Foundation
import Observation
import CabalmailKit

/// Root observable state for the Cabalmail app.
///
/// SwiftUI views consume this via `.environment(...)`; mutations happen on
/// the main actor so view updates don't hop threads. Every network call it
/// fronts — Cognito, config.json, IMAP login — hops to the appropriate
/// actor (the client's, the transport's) and suspends back here for state
/// writes.
@Observable
@MainActor
final class AppState {
    enum Status: Sendable, Equatable {
        case signedOut
        case signingIn
        /// Launched with stored credentials; we're resolving whether they
        /// still work. The UI shows a splash rather than the sign-in form
        /// so the user doesn't see it flash for half a second on every
        /// launch.
        case restoring
        case signedIn
        case error(String)
    }

    var status: Status = .signedOut

    /// Last-used control domain, persisted so repeat launches skip re-entry.
    var controlDomain: String {
        get { UserDefaults.standard.string(forKey: "cabalmail.controlDomain") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "cabalmail.controlDomain") }
    }

    /// Last-used username, same persistence rationale. Passwords are never
    /// persisted here — `CognitoAuthService` holds them in the data-protection
    /// keychain via `KeychainSecureStore`.
    var lastUsername: String {
        get { UserDefaults.standard.string(forKey: "cabalmail.lastUsername") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "cabalmail.lastUsername") }
    }

    private(set) var client: CabalmailClient?

    func signIn(controlDomain: String, username: String, password: String) async {
        status = .signingIn
        do {
            let configuration = try await ConfigLoader.load(controlDomain: controlDomain)
            let cacheDirectory = try makeCacheDirectory()
            let newClient = try CabalmailClient.make(
                configuration: configuration,
                secureStore: KeychainSecureStore(),
                cacheDirectory: cacheDirectory
            )
            try await newClient.authService.signIn(username: username, password: password)
            self.controlDomain = controlDomain
            self.lastUsername = username
            self.client = newClient
            self.status = .signedIn
        } catch let error as CabalmailError {
            status = .error(message(for: error))
        } catch {
            status = .error(error.localizedDescription)
        }
    }

    func signOut() async {
        guard let client else { status = .signedOut; return }
        await client.imapClient.disconnect()
        try? await client.authService.signOut()
        self.client = nil
        self.status = .signedOut
    }

    /// Launch-time auto-restore. Looks at the UserDefaults-persisted
    /// `controlDomain` + `lastUsername` and the Keychain-persisted Cognito
    /// tokens; if all three are present and the refresh token is still
    /// valid (or the ID token hasn't expired), transitions straight to
    /// `.signedIn` without prompting the user.
    ///
    /// Error handling mirrors the plan's cases:
    ///
    /// - Missing inputs (first launch, or post-signout) → silent signed-out.
    /// - Valid tokens → signed-in.
    /// - Refresh-token expired / revoked → clear the keychain so the sign-in
    ///   form starts clean, but keep `lastUsername` / `controlDomain` so
    ///   the form pre-fills.
    /// - Network / transport error → stay signed out *without* clearing
    ///   the keychain, so the next launch (or a manual sign-in) can
    ///   recover without forcing a password re-entry. This is the "airplane
    ///   mode at launch" path.
    /// - Any other error → `.error(message)`.
    ///
    /// Idempotent: if a client is already wired or sign-in is in flight,
    /// this is a no-op, so `.task` can call it without worrying about
    /// SwiftUI's lifecycle re-firing it.
    func restoreIfPossible() async {
        guard client == nil else { return }
        switch status {
        case .signingIn, .restoring, .signedIn:
            return
        default:
            break
        }
        let domain = controlDomain
        let username = lastUsername
        guard !domain.isEmpty, !username.isEmpty else {
            status = .signedOut
            return
        }
        let secureStore = KeychainSecureStore()
        guard (try? secureStore.get(SecureStoreKey.authTokens)) != nil else {
            status = .signedOut
            return
        }

        status = .restoring
        do {
            let configuration = try await ConfigLoader.load(controlDomain: domain)
            let cacheDirectory = try makeCacheDirectory()
            let newClient = try CabalmailClient.make(
                configuration: configuration,
                secureStore: secureStore,
                cacheDirectory: cacheDirectory
            )
            // Touching `currentIdToken()` validates the keychain contents:
            // a fresh ID token returns cached; an expired one triggers a
            // silent refresh; an expired / revoked refresh throws
            // `.authExpired` (Cognito's `NotAuthorizedException`).
            _ = try await newClient.authService.currentIdToken()
            self.client = newClient
            self.status = .signedIn
        } catch let error as CabalmailError {
            switch error {
            case .authExpired, .invalidCredentials, .notSignedIn:
                // Refresh token is gone — clear the keychain so a stale
                // token doesn't keep tripping the sign-in form.
                try? secureStore.remove(SecureStoreKey.authTokens)
                try? secureStore.remove(SecureStoreKey.imapUsername)
                try? secureStore.remove(SecureStoreKey.imapPassword)
                status = .signedOut
            case .network, .transport, .timeout, .cancelled, .notConfigured:
                // Transient — leave the keychain alone. The sign-in form
                // will show but pre-filled, and a retry (or a later launch)
                // has a chance to recover without forcing the user to
                // re-enter their password.
                status = .signedOut
            default:
                status = .error(message(for: error))
            }
        } catch {
            status = .error(error.localizedDescription)
        }
    }

    /// Returns the application-support cache directory for this app, creating
    /// it if needed. Per-folder subdirectories are created by the cache
    /// actors themselves.
    private func makeCacheDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = base.appendingPathComponent("Cabalmail", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func message(for error: CabalmailError) -> String {
        // Most cases fall through to a canned or "prefix: detail" format;
        // split into two switches so neither exceeds the cyclomatic cap.
        if let canned = cannedMessage(for: error) { return canned }
        switch error {
        case .network(let detail):              return "Network error: \(detail)"
        case .transport(let detail):            return "Transport error: \(detail)"
        case .protocolError(let text):          return "Protocol error: \(text)"
        case .server(_, let text):              return "Server error: \(text)"
        case .decoding(let text):               return "Response error: \(text)"
        case .imapCommandFailed(_, let detail): return "IMAP: \(detail)"
        case .smtpCommandFailed(_, let detail): return "SMTP: \(detail)"
        default:                                return "\(error)"
        }
    }

    private func cannedMessage(for error: CabalmailError) -> String? {
        switch error {
        case .invalidCredentials: return "Incorrect username or password."
        case .notConfigured:      return "Control domain is invalid."
        case .authExpired:        return "Session expired. Please sign in again."
        case .timeout:            return "Request timed out."
        case .cancelled:          return "Cancelled."
        case .notSignedIn:        return "Not signed in."
        default:                  return nil
        }
    }
}

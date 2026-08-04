#if os(iOS)
import AppIntents
import CabalmailKit

/// Speakable errors for App Intents. Siri reads `localizedStringResource`
/// aloud, so every case is a full sentence — the intent-side analogue of
/// `AppState.message(for:)`.
enum IntentError: Error, CustomLocalizedStringResourceConvertible {
    case notSignedIn
    case message(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notSignedIn: return "You need to sign in to Cabalmail first."
        case .message(let text): return "\(text)"
        }
    }

    /// Compact mapping of Kit errors to speakable copy.
    static func friendly(_ error: Error) -> IntentError {
        if let error = error as? IntentError { return error }
        guard let error = error as? CabalmailError else {
            return .message(error.localizedDescription)
        }
        switch error {
        case .notSignedIn, .authExpired, .invalidCredentials:
            return .notSignedIn
        case .timeout:
            return .message("The request timed out.")
        // Planned IMAP redeploy / Cognito-trigger copy is user-facing
        // verbatim, same as AppState's canned messages.
        case .maintenance(let message):
            return .message(message)
        case .server(_, let message):
            return .message(message)
        case .network, .transport:
            return .message("Cabalmail could not reach the server.")
        default:
            return .message("\(error)")
        }
    }
}

enum IntentDomains {
    /// Apex domains the user may mint on: the deployment's configured list
    /// intersected with `/list_my_domains`, falling back to the full
    /// configured list when the allow-list fetch fails (mirrors
    /// `NewAddressSheet.loadAllowedDomains`; the `/new` Lambda still
    /// enforces entitlement server-side).
    static func visible(client: CabalmailClient) async -> [String] {
        let configured = client.configuration.domains.map(\.domain)
        guard let allowed = try? await client.allowedDomains() else { return configured }
        let allowedSet = Set(allowed)
        return configured.filter { allowedSet.contains($0) }
    }
}
#endif

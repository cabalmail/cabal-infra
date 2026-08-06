#if os(iOS)
import AppIntents
import UIKit
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

@MainActor
enum IntentClipboard {
    /// Writes to the general pasteboard and reports whether the write took.
    /// A process that isn't foreground can't touch the pasteboard — the
    /// write fails *silently* (FB13636156: "pasteboard name … is not
    /// valid" is only logged) — so callers check the `changeCount` delta
    /// to keep the spoken dialog truthful instead of claiming a copy that
    /// never happened.
    static func copy(_ string: String) -> Bool {
        let pasteboard = UIPasteboard.general
        let before = pasteboard.changeCount
        pasteboard.string = string
        return pasteboard.changeCount != before
    }
}

extension ForegroundContinuableIntent {
    /// Shared tail of both create-address intents. The copy works in place
    /// only when the app happens to be foreground; from Siri the app is
    /// backgrounded, so on a failed write this offers a one-tap hop to the
    /// foreground (where the pasteboard is writable) and completes the copy
    /// there. Declining still returns the address as the intent's value —
    /// a Shortcuts chain keeps working — with a dialog that says where to
    /// find it instead of pretending it was copied.
    @MainActor
    func finishAddressCreation(
        _ address: String
    ) async -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        if IntentClipboard.copy(address) {
            return .result(
                value: address,
                dialog: "Created \(address) and copied it to the clipboard."
            )
        }
        do {
            let copied = try await requestToContinueInForeground(
                IntentDialog("I created \(address). Continue in Cabalmail to copy it?")
            ) {
                await IntentClipboard.copy(address)
            }
            guard copied else {
                return .result(value: address, dialog: Self.createdNotCopiedDialog(address))
            }
            return .result(
                value: address,
                dialog: "Created \(address) and copied it to the clipboard."
            )
        } catch {
            // Declined (or the prompt timed out): the address exists either
            // way — never re-throw, or a Shortcuts chain would abort after
            // the server-side create already happened.
            return .result(value: address, dialog: Self.createdNotCopiedDialog(address))
        }
    }

    private static func createdNotCopiedDialog(_ address: String) -> IntentDialog {
        IntentDialog("Created \(address). You'll find it under Addresses in Cabalmail.")
    }
}
#endif

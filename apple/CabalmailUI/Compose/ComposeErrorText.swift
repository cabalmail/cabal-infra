import CabalmailKit
import Foundation

/// The compose surface's failure sentences.
///
/// The same `CabalmailError` reaches the user from a send and from a draft
/// save, so the reason is written once here and each path adds its own
/// lead. With the lead inside the shared renderer, a save that never sent
/// anything read "Couldn't save draft: Send failed: …" (#1900).
enum ComposeErrorText {

    /// Why the call failed, naming no operation — the caller says which one
    /// it was.
    static func reason(_ error: CabalmailError) -> String {
        switch error {
        case .invalidCredentials: return "your credentials were rejected."
        case .network(let detail): return "Network error: \(detail)"
        case .authExpired: return "Your session expired; please sign in again."
        case .maintenance(let message): return message
        default: return error.localizedDescription
        }
    }

    /// A failed send. Three reasons are already whole sentences about the
    /// connection, the session or the service rather than about this send,
    /// and have always been shown as they are.
    static func sendFailure(_ error: CabalmailError) -> String {
        switch error {
        case .network, .authExpired, .maintenance: return reason(error)
        default: return "Send failed: \(reason(error))"
        }
    }

    /// A failed draft save. The local copy is still on disk, so the lead
    /// says what did not happen rather than what was lost.
    static func draftSaveFailure(_ error: CabalmailError) -> String {
        "Couldn't save draft: \(reason(error))"
    }
}

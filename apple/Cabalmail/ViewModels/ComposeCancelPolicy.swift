import Foundation

/// What closing a composer without sending should do with the buffer.
/// `ComposeViewModel.cancel()` reads this rather than deciding inline,
/// because the decision is an *ordering* — and getting that order wrong is
/// how "Save Draft" came to throw a draft away (#903).
enum ComposeCancelResolution: Equatable {
    /// Editor bridge is dead, so every body converts to `""` (#745). Keep
    /// the local autosave, push nothing to the server, let the window go.
    case closeKeepingLocalCopy
    /// Nothing worth keeping: drop any server copy and the local one.
    case discardEmpty
    /// There is content but no sender to save it under. Refuse and stay in
    /// the composer so the user can pick a From address (or discard).
    case refuseMissingFrom
    /// Push the buffer to the IMAP `Drafts` folder, then close.
    case saveToServer
}

/// Pure decision behind Cancel -> "Save Draft" (and the macOS window-close
/// intercept). Split out of the view model so the order of the three
/// preconditions is unit testable without a WebKit bridge in the loop.
enum ComposeCancelPolicy {
    /// Banner copy for a save refused because no From address is selected.
    /// `/save_draft` has no envelope to authorize against without one, so
    /// there is nothing to do but ask — silently closing loses whatever was
    /// typed, which is the defect this replaces (#903).
    static let missingFromMessage =
        "Couldn't save draft: pick a From address first. Everything you typed is still "
            + "here — choose an address and save again, or use Discard Draft to throw it away."

    /// Order is load-bearing. A dead bridge wins over everything: there is
    /// no body to push and the local copy is already flushed. An empty
    /// compose is next, so opening and closing the composer without a From
    /// still leaves no breadcrumb. Only then does a missing sender matter —
    /// checking it any earlier is what turned "Save Draft" on a half-filled
    /// message into a silent discard.
    static func resolve(
        bridgeFailed: Bool,
        hasContent: Bool,
        hasFrom: Bool
    ) -> ComposeCancelResolution {
        if bridgeFailed { return .closeKeepingLocalCopy }
        guard hasContent else { return .discardEmpty }
        guard hasFrom else { return .refuseMissingFrom }
        return .saveToServer
    }
}

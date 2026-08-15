import Foundation
import CabalmailKit

// Helper value types posted by `AppState` to coordinate one-way signals
// between detail / list / compose views. Each carries a monotonic `tick`
// so `.onChange` fires even when the same logical payload (UID, flag,
// folder) recurs after a folder switch or UIDVALIDITY reset.

/// Ephemeral banner message. Promoted out of `AppState` so the nested
/// `Kind` enum stays at a single level of nesting (SwiftLint's cap).
struct Toast: Equatable, Sendable {
    enum Kind: Sendable { case info, success, warning, error }
    let kind: Kind
    let message: String
    /// When set, the banner renders a trailing "Copy" button that places this
    /// string on the pasteboard. Modeled as data (not a closure) so `Toast`
    /// stays `Equatable`/`Sendable` and the auto-dismiss equality check in
    /// `AppState.showToast` keeps working.
    var copyAddress: String?
    /// When set, the banner renders a trailing "Resume" button that navigates
    /// to this cross-client cursor (last folder/message saved on another
    /// device). Data, not a closure, for the same `Equatable` reason as
    /// `copyAddress`; the banner host maps it to the navigation action.
    var resumeCursor: NavState?

    init(kind: Kind, message: String, copyAddress: String? = nil, resumeCursor: NavState? = nil) {
        self.kind = kind
        self.message = message
        self.copyAddress = copyAddress
        self.resumeCursor = resumeCursor
    }

    /// Banner shown after an address is minted, offering a one-tap copy of
    /// the new address without re-finding it in a list.
    static func addressCreated(_ address: String) -> Toast {
        Toast(
            kind: .success,
            message: "Created \(address)",
            copyAddress: address
        )
    }

    /// Confirmation shown after an address lands on the pasteboard, whether
    /// from a list's copy action or the post-creation banner's Copy button.
    static func addressCopied(_ address: String) -> Toast {
        Toast(kind: .success, message: "Address \(address) successfully copied")
    }

    /// Confirmation shown after an address is revoked (e.g. from the message
    /// header's per-address menu). Mirrors the wording of the address list's
    /// revoke dialog: mail to it will now be rejected.
    static func addressRevoked(_ address: String) -> Toast {
        Toast(kind: .success, message: "Revoked \(address)")
    }

    /// Cross-client prompt shown on foreground when another device has moved
    /// the cursor on. Tapping Resume jumps to `cursor`'s folder/message;
    /// ignoring it leaves this client where it is.
    static func resumeNavigation(folderName: String, cursor: NavState) -> Toast {
        Toast(
            kind: .info,
            message: "Pick up where you left off in \(folderName)?",
            resumeCursor: cursor
        )
    }
}

/// Signal payload for a successful dispose action. Carries the folder path
/// and UIDs so list views in non-matching folders can ignore it, plus a
/// monotonic `tick` so `.onChange` fires even if the same UID value
/// reappears after a folder switch + UIDVALIDITY reset.
///
/// `uids` is usually one element — a disposed message is one row. A
/// send-from-draft names several: every copy its compose session left in
/// Drafts, since an autosave replaces the copy under a new UID and the list
/// may be rendering any of them (#1071). One signal rather than several
/// because `.onChange` observes the latest value, so back-to-back posts in
/// the same update would drop all but the last.
struct DisposedEnvelope: Equatable, Sendable {
    let folderPath: String
    let uids: [UInt32]
    let tick: Int
}

/// Signal payload for a Drafts copy that `/save_draft` replaced in place —
/// posted when a compose session closes via Save Draft rather than Send.
/// Distinct from `DisposedEnvelope` because a replace is not a dispose:
/// something took the retired copy's place, so the list re-points at the
/// survivor instead of advancing to the next message per the user's
/// after-dispose preference (#1078).
struct DraftReplacedSignal: Equatable, Sendable {
    let folderPath: String
    let replacement: DraftReplacement
    let tick: Int
}

/// Signal payload for a flag change driven from outside the list (currently:
/// the detail view toggling `\Seen`). The list view applies this directly to
/// its in-memory envelope so the row updates without a server round trip.
/// `tick` is monotonic so toggling the same flag back and forth still fires
/// the observer.
struct EnvelopeFlagChange: Equatable, Sendable {
    let folderPath: String
    let uid: UInt32
    let flag: Flag
    let added: Bool
    let tick: Int
}

/// Signal payload for a mark-read that should also move the reading pane
/// (the detail toolbar's mark-read control, whose macOS option menu picks
/// where to go next). Distinct from `DisposedEnvelope` because the marked
/// row stays in the list — the observer only advances the selection, it
/// never prunes, and a missing advance target means "stay put" rather than
/// "clear the selection". `tick` is monotonic for the usual reason: marking
/// the same UID read again after an unread round trip must still fire.
struct ReadAdvanceRequest: Equatable, Sendable {
    let folderPath: String
    let uid: UInt32
    let advance: MarkReadAdvance
    let tick: Int
}

/// One message inside a drag payload: the UID plus the mailbox that owns it.
/// Folder-mode lists collapse to a single source; a cross-folder search
/// selection can span several, so each item carries its own `sourceFolder`
/// rather than relying on the sidebar's current selection. Codable so it
/// rides inside the drag `NSItemProvider` (see `MessageDragPayload`).
struct MessageDragItem: Codable, Hashable, Sendable {
    let uid: UInt32
    let sourceFolder: String
}

/// Signal payload for a drag-and-drop move. Posted by a folder row's drop
/// handler in `FolderListView` (which knows the destination) and observed by
/// the active `MessageListView` (which owns the view model that performs the
/// optimistic prune / unread bookkeeping / cache cleanup). `tick` is
/// monotonic so dragging onto the same folder twice still fires the observer.
struct MessageMoveRequest: Equatable, Sendable {
    let destination: String
    let items: [MessageDragItem]
    let tick: Int
}

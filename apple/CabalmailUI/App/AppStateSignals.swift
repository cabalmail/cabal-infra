import Foundation
import CabalmailKit

// Helper value types `AppState` posts — the sign-in reason, the toast and
// the drag-and-drop move request — plus its command bumpers and window
// targeting. What the reader and composer change for the message lists is
// posted on `MailEvents` (`AppState.mailStore.events`).

/// Why the app is showing the sign-in form when the user did not ask for it.
/// A deliberate Sign Out leaves `AppState.signedOutReason` nil and the form
/// blank; an expiry sets this, and the form explains itself (issue #1703).
/// Promoted out of `AppState` alongside `Toast`, for the same nesting reason.
enum SignedOutReason: Sendable, Equatable {
    case sessionExpired
}

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

/// One message inside a drag payload: the UID plus the mailbox that owns it.
/// Folder-mode lists collapse to a single source; a cross-folder search
/// selection can span several, so each item carries its own `sourceFolder`
/// rather than relying on the sidebar's current selection. Codable so it
/// rides inside the drag `NSItemProvider` (see `MessageDragPayload`); its
/// two keys are the payload's wire form, so the item converts to and from
/// a `MessageRef` rather than holding one.
struct MessageDragItem: Codable, Hashable, Sendable {
    let uid: UInt32
    let sourceFolder: String
}

extension MessageDragItem {
    init(_ ref: MessageRef) {
        self.init(uid: ref.uid, sourceFolder: ref.folder)
    }

    /// The dragged message.
    var ref: MessageRef { MessageRef(folder: sourceFolder, uid: uid) }
}

/// Signal payload for a drag-and-drop move. Posted by a folder row's drop
/// handler in `FolderListView` (which knows the destination) and observed by
/// the active `MessageListView` (which owns the view model that performs the
/// optimistic prune / unread bookkeeping / cache cleanup). `tick` is
/// monotonic so dragging onto the same folder twice still fires the observer.
struct MessageMoveRequest: Equatable, Sendable {
    let destination: String
    let items: [MessageDragItem]
    /// The list the drag lifted from (`MessageDragPayload.sourceList`).
    /// Every mounted list in every window observes the request, so only
    /// this one performs the move; nil (a payload without one) is
    /// performed by any list, as before.
    let sourceList: UUID?
    let tick: Int

    /// Whether the list identified by `listID` is the one to perform it.
    func isPerformed(by listID: UUID) -> Bool {
        sourceList.map { $0 == listID } ?? true
    }
}

// MARK: - Command window targeting
//
// Which main window a compose request is for (the menus' own commands go to
// the window in front, `WindowCommands`). `requestCompose` records the
// target in `commandWindow` as it bumps the tick; the observer, through
// `onWindowCommand` (`Views/MainWindowCommandScope.swift`), ask `commandReaches`
// before acting. A nil target reaches every window, which keeps any caller
// that names no window working as it did before targeting existed. A
// data-change reload is not a command (`MailSessionStore.listRefreshTick`).
@MainActor
extension AppState {
    /// Records `window` as the main window most recently in front.
    func noteActiveMainWindow(_ window: UUID) {
        lastActiveMainWindow = window
    }

    /// Forgets a main window that closed, so a command issued from a
    /// compose window cannot be aimed at a window no longer there.
    func forgetMainWindow(_ window: UUID) {
        if lastActiveMainWindow == window { lastActiveMainWindow = nil }
    }

    /// Whether the latest command tick is for the window `window`. A view
    /// outside any main window (nil) answers every tick, as before.
    func commandReaches(_ window: UUID?) -> Bool {
        guard let target = commandWindow, let window else { return true }
        return target == window
    }
}

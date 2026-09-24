import SwiftUI

/// Which macOS menu commands outside the `Message` menu can currently do
/// anything.
///
/// `MessageMenuAvailability` already records the rule this app follows (#985):
/// a command is enabled iff it has something to act on. File ▸ New Message and
/// Mailbox ▸ Refresh both broke it in the same state — every window closed
/// (#1162) — because each dispatches through an `AppState` tick whose only
/// consumer is a modifier installed inside the main window. They answer the
/// rule differently, so they are fixed differently:
///
/// - New Message has something to act on there. The compose `WindowGroup`
///   mounts with no other scene alive, which is why the menu-bar extra's
///   identically-named item opens a composer in exactly that state. It stays
///   enabled, and the command opens the window itself (`ComposeWindowCommand`)
///   instead of routing through a view.
/// - Refresh hard-reloads the message list that is on screen. With no mail
///   surface mounted there is no list to reload, so it dims — the same answer
///   the Message menu gives an empty selection.
struct MailboxMenuAvailability: Equatable {
    /// How many mail surfaces are mounted. `MailRootView` reports both edges:
    /// that view hosts the `MessageListView` which is the sole consumer of
    /// `refreshRequestTick`. A count rather than a flag because macOS can have
    /// several mail windows open — the last one closing is what dims the menu,
    /// not the first.
    private(set) var mountedMailSurfaces = 0
    /// The folder whose message list is on screen, reported by the
    /// folder-scoped `MessageListView` (never the search surface). What
    /// Mailbox ▸ Mark All as Read acts on: the command reaches that list
    /// through `markFolderReadRequestTick`, so with no folder list mounted it
    /// has no consumer and dims, the same answer Refresh gives (#1162).
    private(set) var frontFolderPath: String?

    /// No window showing mail: the launch, signed-out and all-windows-closed
    /// state.
    static let none = MailboxMenuAvailability()

    var mailSurfaceIsMounted: Bool { mountedMailSurfaces > 0 }

    /// A folder's message list came on screen.
    mutating func folderListAppeared(_ path: String) { frontFolderPath = path }

    /// That list went away. Guarded on the path because SwiftUI re-keys the
    /// list per folder and delivers the new list's appear before the old
    /// list's disappear — an unguarded clear would wipe the fresh report.
    mutating func folderListDisappeared(_ path: String) {
        if frontFolderPath == path { frontFolderPath = nil }
    }

    /// A mail surface came on screen.
    mutating func surfaceAppeared() { mountedMailSurfaces += 1 }

    /// A mail surface went away (window closed, sign-out, scene teardown).
    /// Floored at zero: SwiftUI can deliver a disappear whose appear this
    /// instance never saw, and a negative count would leave the menu dimmed
    /// until two surfaces had opened.
    mutating func surfaceDisappeared() {
        mountedMailSurfaces = max(0, mountedMailSurfaces - 1)
    }

    /// New Message opens its own window scene, so it is live whether or not any
    /// other window is open. Dimming it with no window would be the tempting
    /// broad reading of the rule and the wrong one — it would take the one
    /// command that the zero-window state is *supposed* to serve and turn a
    /// silent failure into an advertised one.
    var canCompose: Bool { true }

    /// Refresh needs a list to reload.
    var canRefresh: Bool { mailSurfaceIsMounted }

    /// Mark All as Read needs a folder's list to name and to answer the
    /// command; the search surface has neither.
    var canMarkAllRead: Bool { frontFolderPath != nil }
}

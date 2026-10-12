import SwiftUI
import AppKit
import CabalmailKit
import CabalmailUI

/// Content of the Cabalmail status-item menu (Mac residency).
///
/// Macs receive *silent* pushes and the running app enriches them into
/// local notifications (see docs/push-notifications.md) — a quit app gets
/// no notification at all. The menu-bar presence exists to make "quit"
/// rare: it keeps the app legibly resident even with every window closed,
/// and gives that residency a small use — the Inbox unread count plus
/// Open / New Message / Quit.
///
/// Deliberately minimal (`.menu` style, plain menu items): the unread
/// line mirrors the dock badge's `MailCounts.inboxUnreadCount` (refreshed
/// by the existing badge poller), and both window actions route through
/// the scenes the app already declares. No new data paths — a recent-
/// messages list waits until envelopes are exposed app-wide.
struct MenuBarExtraMenu: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // A Text in a .menu-style extra renders as a disabled menu item:
        // a status line, not an action.
        Text(statusLine)
        Divider()
        Button("Open Cabalmail") {
            // Brings the existing window forward, opening one only when the
            // user has closed the last (`MainMailWindow`): `openWindow(id:)`
            // alone would spawn a second window beside an open one.
            MainMailWindow.show(using: openWindow)
        }
        Button("New Message") {
            // Same route as the File menu: the compose window scene both app
            // targets install, opened directly so it works with every window
            // closed (`ComposeWindowCommand`, #1162). If the user is signed
            // out the scene shows its own "Sign in required" placeholder.
            ComposeWindowCommand.openNewMessage(
                appState: appState,
                openWindow: openWindow
            )
        }
        Divider()
        Button("Quit Cabalmail") {
            NSApp.terminate(nil)
        }
    }

    private var statusLine: String {
        guard appState.client != nil else { return "Not signed in" }
        switch appState.mailStore.counts.inboxUnreadCount {
        case 0: return "No unread mail"
        case 1: return "1 unread message"
        case let count: return "\(count) unread messages"
        }
    }
}

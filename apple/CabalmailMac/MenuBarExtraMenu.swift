import SwiftUI
import AppKit
import CabalmailKit

/// UserDefaults key backing the "Show in menu bar" toggle (default on).
/// Written by the Notifications settings section and read by
/// `CabalmailMacApp` through its `MenuBarExtra(isInserted:)` binding, so
/// flipping the toggle inserts or removes the status item immediately.
let menuBarExtraDefaultsKey = "showMenuBarExtra"

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
/// line mirrors the dock badge's `AppState.inboxUnreadCount` (refreshed
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
            // Calling `openWindow(id:)` on a `WindowGroup` unconditionally
            // spawns a fresh window even when one is already open, which
            // is not what the user expects from a "bring to front" menu
            // item. Prefer the existing window and only fall back to
            // opening a new one when none is present (e.g. the user has
            // closed the last main window).
            if !MainMailWindow.bringToFront() {
                openWindow(id: mainWindowID)
            }
            NSApp.activate()
        }
        Button("New Message") {
            // Same route as the File menu / toolbar: the compose window
            // scene both app targets install. If the user is signed out
            // the scene shows its own "Sign in required" placeholder.
            openWindow(id: composeWindowID, value: Draft())
            NSApp.activate()
        }
        Divider()
        Button("Quit Cabalmail") {
            NSApp.terminate(nil)
        }
    }

    private var statusLine: String {
        guard appState.client != nil else { return "Not signed in" }
        switch appState.inboxUnreadCount {
        case 0: return "No unread mail"
        case 1: return "1 unread message"
        case let count: return "\(count) unread messages"
        }
    }
}

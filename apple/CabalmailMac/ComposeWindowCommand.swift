import SwiftUI
import AppKit
import CabalmailKit
import CabalmailUI

/// Opens a fresh compose window from a macOS command surface.
///
/// Two menu items mean "new message" on the Mac — the menu-bar extra's
/// `New Message` and File ▸ New Message — and both have to work with every
/// window closed, the state the menu-bar residency exists to make ordinary
/// (see `MenuBarExtraMenu`). So both open the compose `WindowGroup`
/// directly (`ComposeCoordinator.openNewWindow`) rather than ask a main
/// window's compose surface, `ComposeRequestRouter` on `SignedInRootView`,
/// which is inside the main window and gone with it (#1162).
///
/// One routine rather than a copy per call site, so the two items cannot drift
/// apart again.
@MainActor
enum ComposeWindowCommand {
    /// Layers a compose scene for a brand-new draft and brings the app forward.
    static func openNewMessage(appState: AppState, openWindow: OpenWindowAction) {
        appState.compose.openNewWindow(seed: Draft(), using: openWindow)
        NSApp.activate()
    }
}

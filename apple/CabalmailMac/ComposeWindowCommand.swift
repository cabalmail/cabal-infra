import SwiftUI
import AppKit
import CabalmailKit

/// Opens a fresh compose window from a macOS command surface.
///
/// Two menu items mean "new message" on the Mac — the menu-bar extra's
/// `New Message` and File ▸ New Message — and both have to work with every
/// window closed, the state the menu-bar residency exists to make ordinary
/// (see `MenuBarExtraMenu`). So both address the compose `WindowGroup`
/// directly rather than bumping `AppState.composeRequestTick`, whose only
/// consumer is `ComposeRequestRouter` on `SignedInRootView` — inside the main
/// window, and gone with it (#1162).
///
/// One routine rather than a copy per call site, so the two items cannot drift
/// apart again.
@MainActor
enum ComposeWindowCommand {
    /// Layers a compose scene for a brand-new draft and brings the app forward.
    static func openNewMessage(appState: AppState, openWindow: OpenWindowAction) {
        // Recycled slot, not the seed itself: keying the group by the seed
        // leaks one retained presentation per session (#1084).
        openWindow(
            id: composeWindowID,
            value: appState.composeSlots.acquire(seed: Draft())
        )
        NSApp.activate()
    }
}

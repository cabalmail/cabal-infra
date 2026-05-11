import SwiftUI
import CabalmailKit

/// macOS and iPadOS open compose as a standalone scene rather than a
/// modal sheet. This file holds the scene declaration plus a small
/// adapter view that lets `ComposeView` build a `ComposeViewModel`
/// inside the new window and dismiss the window when the model fires
/// its `onClose` callback (Send / Save Draft / Discard).
///
/// iPhone keeps the sheet path because iOS phones run a single scene
/// at a time — calling `openWindow` would tear the user away from the
/// mailbox they were just reading instead of layering a new window on
/// top. `composeOpensInWindow` is the single source of truth every
/// entry point consults so the New-Message / Reply / Reply-All /
/// Forward buttons all branch the same way.
///
/// `WindowGroup(for: Draft.self)` keys each compose scene by its seed
/// draft, so the user can have a reply and a forward open
/// side-by-side without one stomping on the other.

/// Stable identifier for the compose `WindowGroup`. Shared by every
/// caller of `openWindow` so the same scene group is targeted from
/// the toolbar, the message detail menus, and the macOS Commands
/// menu.
let composeWindowID = "compose"

/// Whether this platform should open compose as its own window. macOS,
/// iPadOS, and visionOS get real windows; iPhone falls back to the
/// modal sheet path.
@MainActor
var composeOpensInWindow: Bool {
    #if os(macOS) || os(visionOS)
    return true
    #elseif os(iOS)
    return UIDevice.current.userInterfaceIdiom == .pad
    #else
    return false
    #endif
}

/// Compose scene group. Both `CabalmailApp` (iOS / iPadOS / visionOS)
/// and `CabalmailMacApp` install this alongside their main window so
/// `openWindow(id: composeWindowID, value: draft)` reaches a real
/// scene on every platform that supports one.
struct ComposeWindowScene: Scene {
    let appState: AppState
    let preferences: Preferences

    var body: some Scene {
        WindowGroup("New Message", id: composeWindowID, for: Draft.self) { $draft in
            ComposeWindowContent(seed: draft ?? Draft())
                .environment(appState)
                .environment(preferences)
        }
        // Give the macOS compose window a sensible starting size so it
        // doesn't inherit the main mail window's geometry. iPadOS and
        // visionOS manage scene sizing themselves.
        #if os(macOS)
        .defaultSize(width: 720, height: 640)
        #endif
    }
}

/// Resolves the signed-in client + builds a `ComposeViewModel` inside
/// the compose window, wiring `onClose` to `dismissWindow` so Send /
/// Save Draft / Discard close the window the same way Cancel does in
/// the sheet path. The signed-out branch is defensive: if the system
/// restores a compose scene before the user has signed back in we
/// degrade to a placeholder rather than crashing on a missing client.
private struct ComposeWindowContent: View {
    let seed: Draft

    @Environment(AppState.self) private var appState
    @Environment(Preferences.self) private var preferences
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        if let client = appState.client {
            ComposeView(model: ComposeViewModel(
                seed: seed,
                client: client,
                draftStore: client.draftStore,
                preferences: preferences,
                onClose: { dismissWindow() }
            ))
            .environment(appState)
            .environment(preferences)
        } else {
            ContentUnavailableView(
                "Sign in required",
                systemImage: "person.crop.circle.badge.exclamationmark",
                description: Text(
                    "Sign in from the main Cabalmail window to compose a message."
                )
            )
        }
    }
}

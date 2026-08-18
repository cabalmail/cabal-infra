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
/// `WindowGroup(for: ComposeSlot.self)` keys each compose scene by a
/// recycled slot index, so the user can have a reply and a forward open
/// side-by-side without one stomping on the other while the number of
/// presentations SwiftUI retains stays bounded by how many composers are
/// open at once — see `ComposeSlotRegistry` for why the seed cannot be
/// the key (issue #1084).

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
/// `openWindow(id: composeWindowID, value: slot)` reaches a real
/// scene on every platform that supports one.
struct ComposeWindowScene: Scene {
    let appState: AppState
    let preferences: Preferences

    var body: some Scene {
        WindowGroup("New Message", id: composeWindowID, for: ComposeSlot.self) { $slot in
            ComposeWindowContent(slot: slot ?? ComposeSlot(index: 0))
                .environment(appState)
                .environment(preferences)
                .onOpenURL { url in
                    // On macOS the main window group declines external
                    // events (`handlesExternalEvents(matching: [])`, see
                    // CabalmailMacApp) so a mailto: click routes here:
                    // the system spawns a compose window with a default
                    // slot and delivers the URL to it. Park the seed under
                    // that slot; without this the window opens with blank
                    // To/Subject fields.
                    if let mailto = MailtoURL(url) {
                        appState.composeSlots.reseed(
                            slot ?? ComposeSlot(index: 0),
                            with: mailto.draft()
                        )
                    }
                }
                // A mailto: click can cold-launch the app straight into
                // this scene, in which case the main window's `.task` —
                // the usual `restoreIfPossible` call site — may not have
                // run. Idempotent, so calling it again is a no-op when
                // the main window already restored the session.
                .task { await appState.restoreIfPossible() }
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
    let slot: ComposeSlot

    @Environment(AppState.self) private var appState
    @Environment(Preferences.self) private var preferences
    @Environment(\.dismissWindow) private var dismissWindow

    /// What this slot is composing right now. A slot the system restored
    /// at launch was never handed out by this process, so it falls back to
    /// an index-derived blank draft rather than a fresh one — a seed whose
    /// identity changed per body evaluation would rebuild the composer on
    /// every redraw.
    private var seed: Draft {
        appState.composeSlots.seed(for: slot)
            ?? ComposeSlotRegistry.restoredSeed(for: slot)
    }

    var body: some View {
        if let client = appState.client {
            ComposeView(model: ComposeViewModel(
                seed: seed,
                client: client,
                draftStore: client.draftStore,
                preferences: preferences,
                onClose: {
                    // Free the slot before dismissing so the next composer
                    // can recycle this window instead of minting a
                    // presentation SwiftUI will never release.
                    appState.composeSlots.release(slot)
                    // iPadOS shows the home screen when the frontmost
                    // scene is dismissed with no sibling activated; bring
                    // the main mail scene forward first so closing compose
                    // lands back on the split view (see
                    // MainSceneActivation.swift).
                    #if os(iOS)
                    MainMailScene.activate()
                    #endif
                    dismissWindow()
                }
            ))
            // Re-identify by seed: `ComposeView` keeps its model in
            // `@State`, so a recycled slot — or the mailto: handler above
            // replacing the seed — must rebuild the subtree for the new
            // seed to take effect. This is also what releases the previous
            // session's model when a window is reused.
            .id(seed.id)
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

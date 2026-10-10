import SwiftUI
import CabalmailKit

/// macOS and iPadOS open compose as a standalone scene rather than a
/// modal sheet. This file holds the scene declaration plus a small
/// adapter view that lets `ComposeView` build a `ComposeViewModel`
/// inside the new window and dismiss the window when the model fires
/// its `onClose` callback (Send / Save Draft / Discard).
///
/// A host that runs a single scene at a time keeps the sheet path —
/// calling `openWindow` there would tear the user away from the mailbox
/// they were just reading instead of layering a new window on top.
/// `ComposeSurfacePolicy` is the single source of truth every entry point
/// consults so the New-Message / Reply / Reply-All / Forward buttons all
/// branch the same way, and it decides by the environment's
/// `supportsMultipleWindows`, not by device idiom: an iPhone Duo is a
/// phone whose inner display hosts multiple windows and whose outer
/// display does not, so a reply opens beside the message when the device
/// is open and as a sheet when it is closed.
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
public let composeWindowID = "compose"

/// Whether compose opens as its own window or as the modal sheet. A pure
/// rule so it can be tested for both answers on whichever platform the
/// tests run — the caller (`ComposeRequestRouter`) reads the environment.
enum ComposeSurfacePolicy {
    /// - Parameters:
    ///   - supportsMultipleWindows: the SwiftUI environment's
    ///     `supportsMultipleWindows` — true on iPad, on iPhone Duo's inner
    ///     display, and on the window platforms; false on every other
    ///     iPhone and on Duo's outer display, where Apple states new windows
    ///     cannot be created. Measured on the iOS 27.1 simulator: the closed
    ///     Duo reports false with a compact/regular size class.
    ///   - alwaysWindows: `platformAlwaysWindows` — macOS and visionOS open
    ///     a window regardless, since they never present the sheet.
    static func opensInWindow(
        supportsMultipleWindows: Bool,
        alwaysWindows: Bool = platformAlwaysWindows
    ) -> Bool {
        alwaysWindows || supportsMultipleWindows
    }

    /// The host platform, as a value rather than a `#if`, so the rule above
    /// can be exercised for both answers on whichever platform the tests run.
    #if os(macOS) || os(visionOS)
    static let platformAlwaysWindows = true
    #else
    static let platformAlwaysWindows = false
    #endif
}

/// Compose scene group. Both `CabalmailApp` (iOS / iPadOS / visionOS)
/// and `CabalmailMacApp` install this alongside their main window so
/// `openWindow(id: composeWindowID, value: slot)` reaches a real
/// scene on every platform that supports one.
public struct ComposeWindowScene: Scene {
    let appState: AppState
    let preferences: Preferences

    public init(appState: AppState, preferences: Preferences) {
        self.appState = appState
        self.preferences = preferences
    }

    public var body: some Scene {
        WindowGroup("New Message", id: composeWindowID, for: ComposeSlot.self) { $slot in
            ComposeWindowContent(slot: slot)
                .environment(appState)
                .environment(preferences)
                // A scene is its own appearance root — the main window's
                // `preferredColorScheme` does not reach across to this one,
                // so a compose window drew in whatever appearance the OS was
                // in while the rest of the app followed the Theme preference
                // (#1460). Every scene pins it for itself; see
                // AppearancePolicy.
                .themedAppearance(preferences.theme)
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
    /// Nil for a window this process did not open: a scene the system
    /// restored at launch, or one it spawned for a `mailto:` link.
    let slot: ComposeSlot?

    @Environment(AppState.self) private var appState
    @Environment(Preferences.self) private var preferences
    @Environment(\.dismissWindow) private var dismissWindow

    /// The seed a window without a slot composes from. Held per window so
    /// it shares nothing with a slot the registry can hand out, and in
    /// `@State` so its identity is stable across body evaluations — one that
    /// changed per evaluation would rebuild the composer on every redraw.
    @State private var ownSeed = Draft()

    /// Set when this window's composer closes; see
    /// `ComposeSlotRegistry.mayCompose(_:closedOn:)`.
    @State private var closedOn: ComposeSlotRegistry.ClosedCompose?

    /// What this window is composing right now; see
    /// `ComposeSlotRegistry.seed(forWindowWith:ownSeed:)`.
    private var seed: Draft {
        appState.composeSlots.seed(forWindowWith: slot, ownSeed: ownSeed)
    }

    var body: some View {
        composer.onOpenURL { url in
            // On macOS the main window group declines external events
            // (`handlesExternalEvents(matching: [])`, see CabalmailMacApp)
            // so a mailto: click routes here: the system spawns a compose
            // window with no slot and delivers the URL to it. Without this
            // the window opens with blank To/Subject fields.
            guard let mailto = MailtoURL(url) else { return }
            if let slot {
                appState.composeSlots.reseed(slot, with: mailto.draft())
            } else {
                ownSeed = mailto.draft()
            }
        }
    }

    @ViewBuilder
    private var composer: some View {
        if let client = appState.client, appState.composeSlots.mayCompose(seed, closedOn: closedOn) {
            ComposeView(model: ComposeViewModel(
                seed: seed,
                client: client,
                draftStore: client.draftStore,
                preferences: preferences,
                onClose: {
                    closedOn = appState.composeSlots.closedCompose(for: seed)
                    // Free the slot before dismissing so the next composer
                    // can recycle this window instead of minting a
                    // presentation SwiftUI will never release. A window
                    // without a slot holds none, and must not free one a
                    // composer elsewhere is using.
                    if let slot { appState.composeSlots.release(slot) }
                    // iPadOS shows the home screen when the frontmost
                    // scene is dismissed with no sibling activated; bring
                    // the main window last used forward first so closing
                    // compose lands back on the split view (see
                    // MainSceneActivation.swift).
                    #if os(iOS)
                    MainMailScene.activate(fallback: appState.lastActiveMainWindow)
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
        } else if appState.client == nil {
            ContentUnavailableView(
                "Sign in required",
                systemImage: "person.crop.circle.badge.exclamationmark",
                description: Text(
                    "Sign in from the main Cabalmail window to compose a message."
                )
            )
        } else {
            // Closed before the last sign-out, and only still here because
            // SwiftUI keeps closed windows mounted: nothing to compose.
            Color.clear
        }
    }
}

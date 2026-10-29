import SwiftUI
import CabalmailKit

/// The compose window: macOS and visionOS open every compose as a scene
/// of its own rather than a sheet. This file holds the scene declaration
/// plus a small adapter view that lets `ComposeView` build a
/// `ComposeViewModel` inside the new window and dismiss the window when
/// the model fires its `onClose` callback (Send / Save Draft / Discard).
///
/// iOS presents compose as a sheet over the window it was asked from, on
/// iPhone, iPad and iPhone Duo alike (`ComposeSurfacePolicy`), and opens
/// this scene on request: the sheet's "Open in New Window", on an iPad or an
/// open Duo, moves its draft here (`ComposeWindowMove`). The window opens at
/// the tap, before the sheet has read its draft, and waits for it; then it
/// takes over the sheet's draft (`ComposeHandoffClaim`) rather than
/// composing its seed, which carries only the draft's ID. iPadOS also
/// restores compose scenes left open before compose became a sheet, and
/// they have to be able to close.
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
                // The window's fold (`\.foldState`): on an iPhone Duo in book
                // pose the discard question is an alert, as it is over the
                // sheet (`ConfirmationPrompt`), not a popover on the crease.
                .foldGeometry()
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
    @Environment(\.openWindow) private var openWindow
    @Environment(\.scenePhase) private var scenePhase

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
        composer
        .onChange(of: scenePhase) { _, phase in
            windowPhaseChanged(phase)
        }
        .onOpenURL { url in
            // On macOS the main window group declines external events
            // (`handlesExternalEvents(matching: [])`, see CabalmailMacApp)
            // so a mailto: click routes here: the system spawns a compose
            // window with no slot and delivers the URL to it. Without this
            // the window opens with blank To/Subject fields.
            //
            // A window with a slot is composing a draft already, a moved one
            // among them; reseeding it would throw that draft away. The link
            // opens a composer of its own instead (`openLink`).
            guard let mailto = MailtoURL(url) else { return }
            if let slot {
                appState.compose.openLink(mailto.draft(), reaching: slot, isSignedIn: appState.client != nil) {
                    openWindow(id: composeWindowID, value: $0)
                }
            } else {
                ownSeed = mailto.draft()
            }
        }
    }

    @ViewBuilder
    private var composer: some View {
        if let client = appState.client, appState.composeSlots.mayCompose(seed, closedOn: closedOn) {
            if appState.compose.handoffs.awaitsSnapshot(for: seed.id) {
                awaitingDraft
            } else {
                composeView(client: client)
            }
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

    /// A window "Open in New Window" asked for at the tap, before the sheet
    /// has sent its draft: nothing to compose yet, and nothing to tap. A
    /// composer built now would start from the seed, which carries only the
    /// draft's ID. Once the draft comes the composer replaces this and takes
    /// it over; if the sheet keeps it, the composer built then closes the
    /// window once it is in front, saving nothing (`ComposeHandoffClaim`).
    private var awaitingDraft: some View {
        Color.clear.frozen(while: true)
    }

    /// Takes the window off screen. iPadOS shows the home screen when the
    /// frontmost scene is dismissed with no sibling activated, so this brings
    /// the main window the composer came from forward first, else the one
    /// last used, and closing compose lands back on its split view (see
    /// MainSceneActivation.swift).
    private func leave() {
        #if os(iOS)
        MainMailScene.activate(appState.compose.origin(of: slot), fallback: appState.lastActiveMainWindow)
        #endif
        dismissWindow()
    }

    /// A closed window that has left the screen keeps nothing to send: its
    /// composer goes (`ComposeSlotRegistry.mayCompose`). And one the user
    /// brings back from the window switcher leaves again, since the system
    /// still lists it and a phone cannot destroy its session (#2257).
    private func windowPhaseChanged(_ phase: ScenePhase) {
        guard var closed = closedOn, closed.seedID == seed.id else { return }
        switch phase {
        case .background:
            closed.hasLeftScreen = true
            closedOn = closed
        case .active where closed.hasLeftScreen:
            leave()
        default:
            break
        }
    }

    private func composeView(client: CabalmailClient) -> some View {
        ComposeView(model: ComposeViewModel(
            seed: seed,
            client: client,
            draftStore: client.draftStore,
            preferences: preferences,
            handoff: appState.compose.handoffs.pending(for: seed.id),
            onClose: {
                closedOn = appState.composeSlots.closedCompose(for: seed)
                // Free the slot before dismissing so the next composer
                // can recycle this window instead of minting a
                // presentation SwiftUI will never release. A window
                // without a slot holds none, and must not free one a
                // composer elsewhere is using.
                if let slot { appState.composeSlots.release(slot) }
                leave()
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
    }
}

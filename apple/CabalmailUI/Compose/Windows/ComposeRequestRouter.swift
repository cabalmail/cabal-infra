import SwiftUI
import CabalmailKit
#if canImport(AppKit)
import AppKit
#endif

/// One main window's compose surface: where the app's compose requests for
/// this window are shown, from a host that is always in the visible
/// hierarchy.
///
/// Installed once on `SignedInRootView`, it registers with the app's
/// `ComposeCoordinator` under its window's identity while the window is
/// signed in. The coordinator hands it each seed meant for this window: the
/// window's own New Message, Reply and Forward, and a mailto: link when this
/// is the window last used. It registers from its `.task`, so a seed that
/// arrived before the window existed (a cold-launch mailto:, or one that
/// waited out the sign-in) opens over the fresh session.
///
/// Hosts with multiple windows (macOS, iPadOS, visionOS, an open iPhone
/// Duo) hand off to the compose `WindowGroup`, which layers a new scene
/// regardless of what the main window is showing. A single-window host
/// (any other iPhone, a closed Duo) presents the compose sheet from here,
/// the signed-in root — see `ComposeSurfacePolicy`. Which one is decided as
/// each seed arrives, so a Duo that was folded between two requests gets
/// the right surface for each. While the sheet is up the surface takes
/// nothing: the coordinator keeps the next seed, in order, until the sheet
/// closes, so an incoming mailto: never replaces a draft being typed.
///
/// History: the sheet used to live on `MessageListView`. SwiftUI cannot
/// present a sheet from a view in a background tab, so a `mailto:` that
/// arrived while the user was on the Addresses or Settings tab set the
/// sheet state on a view that couldn't present it — the app just stayed
/// on its current screen (an App Review rejection for the default-mail-
/// client request), and the orphaned sheet then popped up whenever the
/// user next visited the Mail tab. Hosting the sheet on the signed-in
/// root presents from any tab, folder, or modal state.
struct ComposeRequestRouter: ViewModifier {
    /// What the registered presenter reads as a seed arrives. A reference,
    /// kept current by the body: the presenter is registered once, and an
    /// environment value it captured then would be the one from that
    /// moment, not the surface the window has now.
    @MainActor
    private final class Surface {
        var opensInWindow = false
    }

    @Environment(AppState.self) private var appState
    @Environment(Preferences.self) private var preferences
    @Environment(\.openWindow) private var openWindow
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows
    @Environment(\.commandWindowID) private var windowID
    @State private var composeSeed: Draft?
    @State private var surface = Surface()
    @State private var presenter: ComposeCoordinator.Presenter?

    func body(content: Content) -> some View {
        content
            .onChange(of: ComposeSurfacePolicy.opensInWindow(supportsMultipleWindows: supportsMultipleWindows),
                      initial: true) { _, inWindow in
                surface.opensInWindow = inWindow
            }
            .task(id: windowID) {
                register()
            }
            .onDisappear(perform: unregister)
            .sheet(item: $composeSeed, onDismiss: sheetClosed) { seed in
                composeSheet(for: seed)
            }
    }

    private func register() {
        unregister()
        let presenter = ComposeCoordinator.Presenter(window: windowID, present: present)
        self.presenter = presenter
        appState.compose.register(presenter)
    }

    private func unregister() {
        if let presenter { appState.compose.unregister(presenter) }
        presenter = nil
    }

    /// Shows `seed`: a compose scene on a multi-window host, else the sheet
    /// hosted by this modifier. False while it cannot
    /// (`ComposeSurfacePolicy.offer`), and the seed stays with the
    /// coordinator.
    private func present(_ seed: Draft) -> Bool {
        let offer = ComposeSurfacePolicy.offer(
            hasClient: appState.client != nil, opensInWindow: surface.opensInWindow, sheetIsUp: composeSeed != nil
        )
        switch offer {
        case .refuse:
            return false
        case .sheet:
            composeSeed = seed
        case .window:
            // Recycled slot, not the seed itself: keying the group by the
            // seed leaks one retained presentation per session (#1084).
            openWindow(id: composeWindowID, value: appState.compose.slot(for: seed, from: windowID))
            #if canImport(AppKit)
            // SwiftUI's openWindow occasionally drops the new compose
            // scene behind the main mail window when triggered from a
            // menu-bar shortcut. Force the app forward so the new window
            // comes to the user instead of stranding it under whatever
            // they were just reading.
            NSApp.activate(ignoringOtherApps: true)
            #endif
        }
        return true
    }

    /// The sheet that held back later seeds has fully dismissed: the
    /// coordinator hands over the next one waiting for this window.
    private func sheetClosed() {
        appState.compose.presenterIsFree()
    }

    @ViewBuilder
    private func composeSheet(for seed: Draft) -> some View {
        if let client = appState.client {
            ComposeView(model: ComposeViewModel(
                seed: seed,
                client: client,
                draftStore: client.draftStore,
                preferences: preferences,
                onClose: { composeSeed = nil }
            ))
            .environment(appState)
            .environment(preferences)
        }
    }
}

extension View {
    /// Installs the window's compose surface. Apply exactly once, on the
    /// signed-in root: a second copy would register a second presenter for
    /// the same window.
    func composeRequestRouter() -> some View {
        modifier(ComposeRequestRouter())
    }
}

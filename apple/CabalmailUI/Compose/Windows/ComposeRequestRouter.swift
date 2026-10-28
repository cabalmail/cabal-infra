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
/// iOS presents the compose sheet from here, the signed-in root, on every
/// iPhone, iPad and iPhone Duo; the Mac and visionOS hand off to the
/// compose `WindowGroup`, which layers a new scene regardless of what the
/// main window is showing (`ComposeSurfacePolicy`). While the sheet is up
/// the surface takes nothing: the coordinator keeps the next seed, in
/// order, until the sheet closes, so an incoming mailto: never replaces a
/// draft being typed.
///
/// The sheet sits on the window's trailing side in a wide, regular window
/// (`ComposeSurfacePolicy.sheetSitsTrailing`). It cannot be swiped away:
/// Cancel is the one way out, and it asks whether to keep the draft. And
/// while it is up the window's navigator says so (`SceneNavigator.composeLock`),
/// so no menu, shortcut or deep link archives, moves or swaps the message
/// behind it.
///
/// Where a second window can open beside this one, an iPad or an open
/// iPhone Duo at regular width, the sheet offers "Open in New Window"
/// (`ComposeSurfacePolicy.offersNewWindow`, read on every pass, so a window
/// narrowed into Slide Over or a closed Duo stops offering it). The move
/// (`ComposeWindowMove`) opens the new window at the tap and freezes the
/// sheet until that window has claimed the draft, then closes it; a move no
/// window claimed leaves the sheet as it was, and the action gone for that
/// sheet.
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
    /// The window's navigator, told while the sheet is up.
    let navigator: SceneNavigator

    @Environment(AppState.self) private var appState
    @Environment(Preferences.self) private var preferences
    @Environment(\.openWindow) private var openWindow
    @Environment(\.commandWindowID) private var windowID
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows
    @State private var composeSeed: Draft?
    @State private var windowIsWide = false
    @State private var presenter: ComposeCoordinator.Presenter?
    @State private var move = ComposeWindowMove()

    func body(content: Content) -> some View {
        content
            // The window's shape, read behind it with the keyboard's region
            // ignored, as `SplitShell` reads its split: a docked keyboard
            // would otherwise make a tall window read as wide the moment a
            // field takes focus, and move the sheet while it is typed in.
            .background {
                Color.clear
                    .onGeometryChange(for: Bool.self) { proxy in
                        proxy.size.width > proxy.size.height
                    } action: { wide in
                        windowIsWide = wide
                    }
                    .ignoresSafeArea(.keyboard)
            }
            .task(id: windowID) {
                register()
            }
            .onDisappear(perform: unregister)
            .onChange(of: composeSeed != nil, initial: true) { _, isUp in
                navigator.composeLock.isUp = isUp
            }
            // A new sign-in brings a new navigator while the sheet stays up.
            .onChange(of: ObjectIdentifier(navigator)) {
                navigator.composeLock.isUp = composeSeed != nil
            }
            .sheet(item: $composeSeed, onDismiss: sheetClosed) { seed in
                composeSheet(for: seed)
                    .frozen(while: move.isMoving)
                    .environment(\.composeWindowOffer, windowOffer)
                    .interactiveDismissDisabled()
                    .sheetPlacement(trailing: ComposeSurfacePolicy.sheetSitsTrailing(
                        windowIsWide: windowIsWide,
                        isRegularWidth: horizontalSizeClass == .regular,
                        isRegularHeight: verticalSizeClass == .regular
                    ))
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

    /// Shows `seed`: a compose scene on the Mac and visionOS, else the sheet
    /// hosted by this modifier. False while it cannot
    /// (`ComposeSurfacePolicy.offer`), and the seed stays with the
    /// coordinator.
    private func present(_ seed: Draft) -> Bool {
        let offer = ComposeSurfacePolicy.offer(
            hasClient: appState.client != nil,
            opensInWindow: ComposeSurfacePolicy.opensInWindow(),
            sheetIsUp: composeSeed != nil
        )
        switch offer {
        case .refuse:
            return false
        case .sheet:
            composeSeed = seed
            move.reset()
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
    /// coordinator hands over the next one waiting for this window, and a
    /// deep link that waited for the sheet opens.
    private func sheetClosed() {
        appState.compose.presenterIsFree()
        if composeSeed == nil { navigator.composeClosed() }
    }

    /// "Open in New Window" for the sheet, or nil where no second window
    /// can open beside this one, or once a move from this sheet was refused.
    private var windowOffer: ComposeWindowOffer? {
        guard ComposeSurfacePolicy.offersNewWindow(
            supportsMultipleWindows: supportsMultipleWindows,
            isRegularWidth: horizontalSizeClass == .regular
        ), !move.refused else { return nil }
        let route = ComposeWindowMove.Route(
            compose: appState.compose,
            origin: windowID,
            navigator: navigator,
            openWindow: { openWindow(id: composeWindowID, value: $0) },
            closeSheet: { composeSeed = nil }
        )
        return .moving(with: move, along: route)
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
    func composeRequestRouter(_ navigator: SceneNavigator) -> some View {
        modifier(ComposeRequestRouter(navigator: navigator))
    }
}

import SwiftUI
import CabalmailKit

/// Signed-in root: the window picks one layout shell and switches on it.
///
/// The shell is a `ShellLayout`, resolved from the platform and, on iOS, the
/// horizontal *and* vertical size classes and the measured width
/// (`SectionLayoutPolicy`), never from the device idiom or orientation:
///
/// - `tabs` (`TabShell`) — compact in either dimension: every iPhone in
///   every orientation, iPhone Duo's outer display, an iPad window in narrow
///   multitasking. A bottom tab bar, one tab per section; the Mail tab's
///   sidebar browses and manages folders, so there is no Folders tab.
///   Requiring a regular height too is what keeps a Plus / Max iPhone here in
///   landscape, where its width alone reads as regular; branching on width
///   alone rebuilt the whole tree on rotation, dropping the reader (see the
///   policy's doc). The shell also pins the environment size class to
///   compact, so the Mail tab's split view never expands in landscape and
///   collapses back.
/// - `split` (`SplitShell`) — regular in both: an iPad, iPhone Duo's inner
///   display. A list beside the reader, with the folder list in a floating
///   panel, addresses in a trailing inspector and Settings in a sheet, opened
///   by the panel's gear or the ⌘, command sent to the window as
///   `WindowCommand.settings`.
/// - `ornament` (`OrnamentShell`) — visionOS: a floating leading tab bar,
///   one tab per section, with the folder list a tab of its own.
/// - `desktop` (`DesktopShell`) — macOS: the three-column window, with the
///   three sections' settings in the Settings scene (⌘,, `SettingsTabsView`).
///
/// The window's navigation (`SceneNavigator`) is held here, above the switch,
/// so a swap between shells rebuilds only the layout.
struct SignedInRootView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.commandWindowID) private var commandWindowID
    /// This window's navigation, held here — above the layout switch — so a
    /// swap between the tab tree and the split rebuilds only the layout and
    /// the window keeps its folder, message and tab (`SceneNavigator`).
    @State private var navigator: SceneNavigator
    /// The window's stored route (`ContentView`), which the navigator starts
    /// on and `WindowPlaceKeeper` keeps current.
    @Binding private var storedRoute: Data?
    /// This window's menu commands (`WindowCommands`), published to the menus.
    @State private var windowCommands: WindowCommands
    @State private var isOffline = false
    @State private var failedSends = FailedSendMonitor()
    /// The window width the section layout was last laid out at; see
    /// `SectionLayoutPolicy.layout(isCompactWidth:isCompactHeight:measuredWidth:)`.
    @State private var measuredWidth: CGFloat?
    // iOS only: the shell choice reads both size classes there. visionOS and
    // macOS have one shell each (`ShellLayout.resolve`), so neither compiles
    // this state — guarding it to `os(iOS)` keeps them warning-clean.
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    #endif

    /// - Parameters:
    ///   - appState: read once, to seed the navigator from the session's
    ///     coordinator (a `@State` initial value can't reach the
    ///     environment). SwiftUI keeps the first navigator for the view's life.
    ///   - windowID: the window's identity, so its first landing knows
    ///     whether it records.
    ///   - storedRoute: the window's scene-stored route; one stored for
    ///     another account is ignored.
    init(appState: AppState, windowID: UUID?, storedRoute: Binding<Data?>) {
        _storedRoute = storedRoute
        let navigator = SceneNavigator(
            appState: appState, windowID: windowID,
            storedRoute: StoredRoute.route(in: storedRoute.wrappedValue, for: appState.routeAccount)
        )
        _navigator = State(initialValue: navigator)
        _windowCommands = State(initialValue: WindowCommands(navigator: navigator))
    }

    var body: some View {
        sectionLayout
            .environment(navigator)
            .environment(\.windowCommands, windowCommands)
            .environment(\.shellLayout, shellLayout)
            // A new navigator — a new sign-in — gets new trees, which land
            // on it rather than keep the last account's.
            .id(ObjectIdentifier(navigator))
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { width in
                measuredWidth = width
            }
            // Bottom-anchored since #1426: at the top the banners covered the
            // filter pills and clipped the first message row.
            .overlay(alignment: .bottom) {
                statusBanners
                    .animation(.default, value: isOffline)
                    .animation(.default, value: appState.toast)
                    .animation(.default, value: failedSends.visible.map(\.id))
            }
            .task { await observeReachability() }
            .task(id: appState.client.map { ObjectIdentifier($0) }) { await failedSends.observe(appState.client) }
            // The cross-device "pick up where you left off" probe, at launch
            // and each time this window returns to the front. Here — the one
            // view every layout keeps mounted — rather than in the mail view,
            // so an iPhone that launches into the Feeds tab still offers
            // another device's position, mail or feed (resume-session plan,
            // Phase C). The window's own phase, not the app's: only a main
            // window shows the offer, and the app can come forward through a
            // compose window alone. `AppState` asks once for windows that
            // come forward together.
            .task { await appState.offerCrossDeviceCursor(atLaunch: true) }
            .onChange(of: scenePhase) { old, new in
                guard new == .active, old != .active,
                      appState.navCoordinator?.hasLoadedInitial == true else { return }
                Task { await appState.offerCrossDeviceCursor(atLaunch: false) }
            }
            // This window's compose surface (its New Message, Reply and
            // Forward, and a mailto: link). Lives here — not on
            // MessageListView — because this view is in the visible hierarchy
            // in every tab, folder, and modal state; see ComposeRequestRouter.
            .composeRequestRouter()
            .focusedSceneValue(\.windowCommands, windowCommands)
            // The window's navigator takes the deep links aimed at it, and a
            // link parked before it existed (`DeepLinkRouter`).
            .onChange(of: commandWindowID, initial: true) { _, id in
                navigator.windowID = id
                appState.deepLinks.register(navigator)
            }
            .onDisappear { appState.deepLinks.unregister(navigator) }
            .modifier(WindowPlaceKeeper(navigator: navigator, storedRoute: $storedRoute))
            .onChange(of: shellLayout, initial: true) { old, new in
                navigator.layoutChanged(wasWide: old.isWideSplit, isWide: new.isWideSplit)
            }
            // A new sign-in gets a new navigator, as it gets a new
            // coordinator: nothing of the last account's place carries over.
            .onChange(of: appState.client.map { ObjectIdentifier($0) }) {
                navigator = SceneNavigator(appState: appState, windowID: commandWindowID)
                windowCommands = WindowCommands(navigator: navigator)
                appState.deepLinks.register(navigator)
            }
    }

    /// One arm per shell. `ShellLayout.resolve` gives each platform only its
    /// own shells, so the arms another platform can't reach compile to
    /// nothing there.
    @ViewBuilder
    private var sectionLayout: some View {
        switch shellLayout {
        case .desktop:
            #if os(macOS)
            DesktopShell()
            #endif
        case .split:
            #if os(iOS)
            SplitShell()
            #endif
        case .tabs:
            #if os(iOS)
            // The tab comes from the navigator, so a tree rebuilt mid-process
            // (a fold, an iPad window narrowing) opens on the tab it left.
            TabShell()
            #endif
        case .ornament:
            #if os(visionOS)
            // A floating leading tab bar (Mail / Folders / Feeds / Addresses /
            // Settings / Search) rather than the iPad single-sidebar split —
            // see `OrnamentShell`.
            OrnamentShell()
            #endif
        }
    }

    /// This window's layout shell. On iOS, both size classes and the measured
    /// width, no idiom — see `SectionLayoutPolicy` for why the width alone is
    /// not enough on an iPhone and why the idiom is too much on an iPhone
    /// Duo. macOS and visionOS have one shell each, and no size classes to
    /// read on the Mac.
    private var shellLayout: ShellLayout {
        #if os(iOS)
        ShellLayout.resolve(
            on: .current,
            isCompactWidth: horizontalSizeClass == .compact,
            isCompactHeight: verticalSizeClass == .compact,
            measuredWidth: measuredWidth
        )
        #else
        ShellLayout.resolve(on: .current, isCompactWidth: false, isCompactHeight: false, measuredWidth: measuredWidth)
        #endif
    }

    @ViewBuilder
    private var statusBanners: some View {
        VStack(spacing: 8) {
            if isOffline {
                BannerView(
                    icon: "wifi.slash",
                    text: "Offline — some actions will retry automatically.",
                    tint: ColorTokens.warningFg
                )
            }
            if !failedSends.visible.isEmpty, let client = appState.client {
                FailedSendBanner(monitor: failedSends, client: client)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if let toast = appState.toast {
                // The offline banner above carries no dismissal: it reports a
                // state that is still true, so hiding it would only make the
                // app quieter about being offline (#1426).
                ToastBanner(
                    toast: toast,
                    onAction: actionHandler(for: toast),
                    onDismiss: { appState.toast = nil }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.bottom, bannerBottomInset)
        .padding(.horizontal, 12)
    }

    /// Lift the banners above the tab bar wherever one occupies that band —
    /// see `StatusBannerPlacement`. Keyed on the layout actually drawn, not
    /// the raw size class: a Plus / Max iPhone in landscape is regular-width
    /// but still shows the tab bar.
    private var bannerBottomInset: CGFloat {
        StatusBannerPlacement.bottomInset(in: shellLayout)
    }

    /// Builds the banner's trailing action. A `copyAddress` toast copies and
    /// swaps in the shared "successfully copied" confirmation; a `resumeCursor`
    /// toast moves this window to the cross-client cursor — this window's
    /// navigator, not whichever window answers an app-wide request first
    /// (#1845) — and dismisses the banner. Returns nil for plain status toasts
    /// (no trailing button).
    private func actionHandler(for toast: Toast) -> (() -> Void)? {
        if let address = toast.copyAddress {
            return {
                copyToPasteboard(address)
                appState.showToast(.addressCopied(address), duration: 7)
            }
        }
        if let cursor = toast.resumeCursor {
            return {
                if cursor.kind == .rss {
                    Task {
                        guard let target = await appState.navCoordinator?.requestFeedNavigation(cursor) else { return }
                        navigator.navigateFeeds(to: target)
                    }
                } else {
                    navigator.navigate(to: cursor)
                }
                appState.toast = nil
            }
        }
        return nil
    }

    /// Mirrors `Reachability.isReachable` into view state. The kit side only
    /// exposes a stream — reading the stream with `for await` is the
    /// officially-supported way to observe NWPathMonitor transitions from
    /// Swift concurrency.
    private func observeReachability() async {
        #if canImport(Network)
        guard let reachability = appState.client?.reachability else { return }
        for await reachable in reachability.changes() {
            isOffline = !reachable
        }
        #endif
    }
}

#if !os(macOS)
/// Addresses tab for the tab shells (`TabShell` and `OrnamentShell`): the
/// shared `AddressListView` in its own `NavigationStack`. The tab is a
/// management surface — tap copies the address, and
/// request/revoke/favorite/suspend live on the rows.
struct AddressManagementTab: View {
    var body: some View {
        NavigationStack {
            AddressListView(externalFilter: nil)
        }
    }
}
#endif

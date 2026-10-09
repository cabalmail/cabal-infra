import SwiftUI
import CabalmailKit

/// Signed-in root.
///
/// The section layout (Mail / Feeds / Addresses / Settings, plus a Search tab)
/// branches on the horizontal *and* vertical size classes
/// (`SectionLayoutPolicy`), never on device idiom or orientation:
///
/// - Compact in either dimension — every iPhone in every orientation, iPhone
///   Duo's outer display, iPad in narrow multitasking: a bottom `TabView`, one
///   tab per section. This is the natural compact idiom and the inner
///   `MailRootView` `NavigationSplitView` collapses to a stack here, so the
///   two never compete for the left edge. There's no dedicated Folders tab
///   — the Mail tab's sidebar `FolderListView` already browses and manages
///   folders. Requiring a regular height too is what keeps a Plus / Max
///   iPhone here in landscape, where its width alone reads as regular;
///   branching on width alone rebuilt the whole tree on rotation, dropping
///   the reader (see the policy's doc). The tab tree also pins the
///   environment size class to compact, so the split view inside it never
///   expands in landscape and collapses back (the cycle that left the reader
///   unpushed and the addresses inspector stranded as a sheet over the tab
///   bar).
/// - Regular in both — an iPad, iPhone Duo's inner display: just
///   `MailRootView` — a single show/hide sidebar owns the left edge, matching
///   the macOS main window. Addresses / Folders / Settings move into a modal
///   `SettingsSheet`, opened by the sidebar gear button or the ⌘, app command
///   via `AppState.settingsRequestTick`.
/// - visionOS: `VisionSectionView` — a floating leading tab bar (the visionOS
///   `TabView` ornament), one tab per section. The iPad single-sidebar layout
///   hid the folder list behind a reveal toggle visionOS never surfaced, so it
///   gets the tab idiom instead (the folder list is its own tab there).
/// - macOS renders `MailRootView` directly and reaches the three sections
///   through its dedicated Settings scene (⌘,, `SettingsTabsView`).
///
/// The regular-width branch replaced an earlier `TabView(.sidebarAdaptable)`
/// that governed every iOS width. Its adaptive top-bar / sidebar chrome was
/// harmless on compact (it renders as a plain tab bar) but collided with
/// `MailRootView`'s own `NavigationSplitView` at regular width: the section
/// bar overlapped the split view's headers, and sidebar mode stacked two
/// redundant rails.
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
    @State private var isOffline = false
    @State private var failedSends = FailedSendMonitor()
    /// The window width the section layout was last laid out at; see
    /// `SectionLayoutPolicy.layout(isCompactWidth:isCompactHeight:measuredWidth:)`.
    @State private var measuredWidth: CGFloat?
    // iPad only: the regular-width branch below reads the size class and
    // presents the Settings sheet. visionOS uses its own tab bar
    // (`VisionSectionView`) and macOS its Settings scene, so neither compiles
    // this state — guarding it to `os(iOS)` keeps them warning-clean.
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var settingsPresented = false
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
        _navigator = State(initialValue: SceneNavigator(
            appState: appState, windowID: windowID,
            storedRoute: StoredRoute.route(in: storedRoute.wrappedValue, for: appState.routeAccount)
        ))
    }

    var body: some View {
        sectionLayout
            .environment(navigator)
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
            // and on each return to the foreground. Here — the one view every
            // layout keeps mounted — rather than in the mail view, so an
            // iPhone that launches into the Feeds tab still offers another
            // device's position, mail or feed (resume-session plan, Phase C).
            .task { await offerCrossDeviceCursor(atLaunch: true) }
            .onChange(of: scenePhase) { old, new in
                guard new == .active, old != .active,
                      appState.navCoordinator?.hasLoadedInitial == true else { return }
                Task { await offerCrossDeviceCursor(atLaunch: false) }
            }
            // App-wide compose-request receiver (mailto: URLs, menu and
            // toolbar New Message). Lives here — not on MessageListView —
            // because this view is in the visible hierarchy in every tab,
            // folder, and modal state; see ComposeRequestRouter.
            .composeRequestRouter()
            .onChange(of: commandWindowID, initial: true) { _, id in navigator.windowID = id }
            .modifier(WindowPlaceKeeper(navigator: navigator, storedRoute: $storedRoute))
            #if os(iOS)
            .onChange(of: layoutChoice, initial: true) { _, layout in
                navigator.layoutIsWide = layout == .regularSplit
            }
            #elseif os(macOS)
            .onAppear { navigator.layoutIsWide = true }
            #endif
            // A new sign-in gets a new navigator, as it gets a new
            // coordinator: nothing of the last account's place carries over.
            .onChange(of: appState.client.map { ObjectIdentifier($0) }) {
                navigator = SceneNavigator(appState: appState, windowID: commandWindowID)
            }
            // Push, Spotlight and Siri write one app-wide request; the first
            // window to see it takes it.
            .onChange(of: appState.navCoordinator?.navigateRequest) {
                navigator.takeNavigateRequest()
            }
    }

    private func offerCrossDeviceCursor(atLaunch: Bool) async {
        guard let coordinator = appState.navCoordinator else { return }
        let candidate = atLaunch
            ? await coordinator.launchResumeCandidate()
            : await coordinator.foreignCursorOnForeground()
        guard let candidate else { return }
        let title = await coordinator.resumeTitle(for: candidate)
        appState.showToast(.resumeNavigation(folderName: title, cursor: candidate), duration: 10)
    }

    @ViewBuilder
    private var sectionLayout: some View {
        #if os(macOS)
        MailRootView()
        #elseif os(visionOS)
        // A floating leading tab bar (Mail / Folders / Addresses / Settings /
        // Search) rather than the iPad single-sidebar split — see
        // `VisionSectionView`.
        VisionSectionView()
        #else
        switch layoutChoice {
        case .compactTabs:
            // The tab comes from the navigator, so a tree rebuilt mid-process
            // (a fold, an iPad window narrowing) opens on the tab it left.
            CompactSectionTabs()
                // The tab tree is compact width throughout, whatever the raw
                // size class says in landscape on a Plus / Max: the Mail
                // tab's split view must never expand into columns and
                // collapse back, and the addresses inspector must never
                // change presentation. See `SectionLayoutPolicy`.
                .transformEnvironment(\.horizontalSizeClass) { sizeClass in
                    sizeClass = .compact
                }
        case .regularSplit:
            MailRootView()
                .environment(\.showsSettingsGear, true)
                .sheet(isPresented: $settingsPresented) {
                    SettingsSheet()
                }
                // The gear button and the ⌘, command both bump the tick;
                // routing through it (rather than a direct binding) keeps the
                // trigger working regardless of which column holds focus.
                .onWindowCommand(appState.settingsRequestTick) {
                    settingsPresented = true
                }
        }
        #endif
    }

    #if os(iOS)
    /// Both size classes, no idiom — see `SectionLayoutPolicy` for why the
    /// width alone is not enough on an iPhone and why the idiom is too much
    /// on an iPhone Duo.
    private var layoutChoice: SectionLayoutPolicy.Layout {
        SectionLayoutPolicy.layout(
            isCompactWidth: horizontalSizeClass == .compact,
            isCompactHeight: verticalSizeClass == .compact,
            measuredWidth: measuredWidth
        )
    }

    #endif

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
        #if os(iOS)
        StatusBannerPlacement.bottomInset(isRegularWidth: layoutChoice == .regularSplit)
        #else
        StatusBannerPlacement.defaultBottomInset
        #endif
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
/// Addresses tab for the compact-iPhone bottom bar and the visionOS tab bar
/// (`VisionSectionView`): the shared `AddressListView` in its own
/// `NavigationStack`. The tab is a management surface — tap copies the
/// address, and request/revoke/favorite/suspend live on the rows.
/// Module-internal (not `private`) so `VisionSectionView` can reuse it.
struct AddressManagementTab: View {
    var body: some View {
        NavigationStack {
            AddressListView(externalFilter: nil)
        }
    }
}
#endif

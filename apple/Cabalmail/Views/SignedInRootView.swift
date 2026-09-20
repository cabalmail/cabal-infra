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
    @State private var isOffline = false
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

    var body: some View {
        sectionLayout
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
            }
            .task { await observeReachability() }
            // App-wide compose-request receiver (mailto: URLs, menu and
            // toolbar New Message). Lives here — not on MessageListView —
            // because this view is in the visible hierarchy in every tab,
            // folder, and modal state; see ComposeRequestRouter.
            .composeRequestRouter()
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
            // Seeded from the live coordinator so a tree rebuilt mid-process
            // (a fold, an iPad window narrowing) opens on the section the
            // split was showing; the stored session covers a cold launch,
            // before the coordinator exists. See `CompactSectionTabs` for why
            // the selection lives on that view and not here.
            CompactSectionTabs(
                initialSection: appState.navCoordinator?.launchSection ?? ResumeSessionStore.storedSection()
            )
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
                .onChange(of: appState.settingsRequestTick) { _, _ in
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
    /// toast asks the nav coordinator to navigate to the cross-client cursor
    /// and dismisses the banner. Returns nil for plain status toasts (no
    /// trailing button).
    private func actionHandler(for toast: Toast) -> (() -> Void)? {
        if let address = toast.copyAddress {
            return {
                copyToPasteboard(address)
                appState.showToast(.addressCopied(address), duration: 7)
            }
        }
        if let cursor = toast.resumeCursor {
            return {
                appState.navCoordinator?.navigateRequest = cursor
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

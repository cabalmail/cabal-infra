import SwiftUI
import CabalmailKit

#if os(iOS)
/// The tab layout's shell: a plain bottom tab bar, one tab per section —
/// iPhone in every orientation, iPhone Duo's outer display, and an iPad
/// window narrowed to compact. No `.sidebarAdaptable`: at compact width
/// there's no sidebar to adapt to.
///
/// The tabs are `CompactTab.tabs(for: .tabs)`, each drawn with its own
/// title, symbol and role. The Search tab takes the search role and, on
/// iOS 26 and later, activates its field when selected
/// (`.tabViewSearchActivation(.searchTabSelection)`). That sets the Search
/// button apart at the bar's trailing end, and tapping it morphs the button
/// into `SearchView`'s field at the bottom while the rest of the bar
/// collapses to one button for the tab the user came from; the field's
/// dismiss button, or that one, goes back to it. Search isn't a place of its
/// own until a search runs: it opens over the tab in front, which the Search
/// tab shows, dimmed, until the first search is submitted
/// (`SearchBackdrop`). Without the activation the Search button is a fifth
/// tab in the bar, and opens a Search screen with its field at the top.
///
/// The Mail tab is `CompactMailStack`: folders, list and reader with no
/// search of its own, so the Search tab's query never reaches it (#1970,
/// #1996). The Addresses tab hosts the same `AddressListView` the wide
/// shells' inspector does (`AddressManagementTab`), so there's a single list
/// implementation per data type. Folders have no dedicated tab: the Mail
/// tab's sidebar browses and manages them.
///
/// Every tab wraps its content in `tabBarTrayShield()`: the floating bar
/// only draws the capsules, so without it, touches in the tray's margins
/// fall through to the rows visible behind the bar (see
/// `TabBarTrayShield.swift`). Each names its tab (`commandTab`): shown tabs
/// stay mounted, and only the one in front answers the menus.
///
/// Every tab's root screen heads itself with the Cabalmail mark in place
/// of its text title, the way the Mail tab's folder list always has:
/// `showsCompactBrandMark` turns on the `compactBrandMarkTitle()` each
/// root applies (see `SidebarBranding.swift`). Set on the `TabView` so a
/// tab added later inherits it.
///
/// The selected tab is the window's `SceneNavigator.compactTab`, which lives
/// above the layout switch: close an iPhone Duo, or narrow an iPad window,
/// and the tab bar comes back on the tab it left — or, after reading in the
/// split, on the section the split was showing, which the navigator follows
/// there (#1644). The navigator seeds it from the resume session when the
/// window is created, so it is settled before the Mail tab can appear and
/// land.
struct TabShell: View {
    @Environment(SceneNavigator.self) private var navigator

    /// Captures the tab in front as Search opens over it.
    @State private var backdropCapture = SearchBackdropCapture()
    /// What the Search tab shows until a search runs: the tab Search was
    /// opened over. Dropped once another tab is in front, however it got
    /// there.
    @State private var searchBackdrop: SearchBackdrop?

    /// The tab bar's selection, through the navigator so a switch notes the
    /// section on the resume session.
    private var tab: Binding<CompactTab> {
        Binding(get: { navigator.compactTab }, set: { select($0) })
    }

    var body: some View {
        TabView(selection: tab) {
            ForEach(CompactTab.tabs(for: .tabs), id: \.self) { tab in
                if tab.role(in: .tabs) == .search {
                    Tab(value: tab, role: .search) {
                        content(for: tab)
                    }
                } else {
                    Tab(LocalizedStringKey(tab.title), systemImage: tab.systemImage, value: tab) {
                        content(for: tab)
                    }
                }
            }
        }
        .searchActivatesOnSelection()
        .background { backdropCapture.windowReader }
        .onChange(of: navigator.compactTab) { _, tab in
            if tab != .search { searchBackdrop = nil }
        }
        .environment(\.showsCompactBrandMark, true)
        // ⌘, opens Settings: its own tab here, as on visionOS.
        .answersCommand(.settings) { navigator.showTab(.settings) }
        // The tab tree is compact width throughout, whatever the raw size
        // class says in landscape on a Plus / Max: the Mail tab's split view
        // must never expand into columns and collapse back. See
        // `SectionLayoutPolicy`.
        .transformEnvironment(\.horizontalSizeClass) { sizeClass in
            sizeClass = .compact
        }
    }

    private func content(for tab: CompactTab) -> some View {
        Group {
            switch tab {
            case .mail: CompactMailStack(titleMarkSize: compactBrandMarkSize)
            case .feeds: FeedRootView()
            case .addresses: AddressManagementTab()
            case .settings: SettingsView()
            case .search: SearchView(backdrop: fittingBackdrop)
            case .folders: EmptyView()
            }
        }
        .tabBarTrayShield()
        .environment(\.commandTab, tab)
    }

    /// The backdrop while it still matches the window: a rotation or a
    /// resize while Search is open leaves the Search tab its own surface.
    private var fittingBackdrop: SearchBackdrop? {
        guard let searchBackdrop, let windowSize = backdropCapture.windowSize,
              searchBackdrop.fits(windowSize) else { return nil }
        return searchBackdrop
    }

    /// A tap on the bar. A tap on Search captures the tab it opens over
    /// first. A switch the app makes itself (a fold carrying a search across)
    /// goes straight to the navigator and captures nothing.
    private func select(_ tab: CompactTab) {
        let leaving = navigator.compactTab
        if tab == .search, leaving != .search {
            searchBackdrop = backdrop(over: leaving)
        }
        navigator.showTab(tab)
    }

    /// The Search tab's stand-in for `tab`, or nil where Search doesn't open
    /// over the tab in front: before iOS 26 it's a tab of its own, its field
    /// in the navigation bar the backdrop would hide.
    private func backdrop(over tab: CompactTab) -> SearchBackdrop? {
        guard #available(iOS 26, *), let frame = backdropCapture.capture() else { return nil }
        return SearchBackdrop(
            image: Image(uiImage: frame.image),
            size: frame.size,
            tabTitle: tab.title,
            returnToTab: { navigator.showTab(tab) }
        )
    }
}

private extension View {
    /// Selecting the Search tab activates its field, and dismissing the field
    /// goes back to the tab selected before it: `.searchTabSelection`, which
    /// also sets the Search button apart from the rest of the bar. Before
    /// iOS 26 the Search tab is a plain tab.
    @ViewBuilder
    func searchActivatesOnSelection() -> some View {
        if #available(iOS 26, *) {
            tabViewSearchActivation(.searchTabSelection)
        } else {
            self
        }
    }
}
#endif

import SwiftUI
import CabalmailKit

#if os(iOS)
/// The tab layout's shell: a plain bottom tab bar, one tab per section —
/// iPhone in every orientation, iPhone Duo's outer display, and an iPad
/// window narrowed to compact. No `.sidebarAdaptable`: at compact width
/// there's no sidebar to adapt to.
///
/// The tabs are `CompactTab.tabs(for: .tabs)`, each drawn with its own
/// title, symbol and role. The Search tab takes the search role, which
/// detaches it to the bottom-right next to the bar and, on iOS 26 and
/// later, morphs the bar into a dismiss button and the tab into a focused
/// field (from `SearchView`'s `.searchable`).
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

    /// The tab bar's selection, through the navigator so a switch notes the
    /// section on the resume session.
    private var tab: Binding<CompactTab> {
        Binding(get: { navigator.compactTab }, set: { navigator.showTab($0) })
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
            case .search: SearchView()
            case .folders: EmptyView()
            }
        }
        .tabBarTrayShield()
        .environment(\.commandTab, tab)
    }
}
#endif

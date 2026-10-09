import SwiftUI
import CabalmailKit

/// Tab identities for the tab-bar layouts: the compact tab bar and
/// visionOS's. `resumeSection` maps the content tabs onto the resume
/// session's sections; the utility tabs have none. Folders is visionOS's
/// alone (the compact Mail tab browses folders in its own sidebar), and
/// belongs to mail.
enum CompactTab: Hashable {
    case mail, folders, feeds, addresses, settings, search

    var resumeSection: ResumeSession.Section? {
        switch self {
        case .mail, .folders: return .mail
        case .feeds: return .feeds
        case .addresses, .settings, .search: return nil
        }
    }

    /// The tab a freshly built tab tree opens on: Feeds when the resume
    /// session (live or stored) ended in the feed reader, Mail otherwise.
    /// The utility tabs are never a landing — they are not sections of the
    /// session, so nothing can ask for them.
    static func initial(for section: ResumeSession.Section?) -> CompactTab {
        section == .feeds ? .feeds : .mail
    }
}

#if os(iOS)
/// Compact-width section switcher: a plain bottom tab bar. No
/// `.sidebarAdaptable` - at compact width there's no sidebar to adapt to,
/// and the regular-width path never renders this, so the adaptive style's
/// collision with the inner split view can't recur.
///
/// The Addresses tab hosts the same `AddressListView` the Mail sidebar uses
/// (wrapped in `AddressManagementTab` for its own `NavigationStack` +
/// selection). That list carries the full request/revoke affordances, so
/// there's a single list implementation per data type - the old dedicated
/// management views were retired. Folders have no dedicated tab: the Mail
/// tab's sidebar `FolderListView` already browses and manages them
/// (create/delete/subscribe live on its rows and toolbar).
///
/// Every tab wraps its content in `tabBarTrayShield()`: the floating bar
/// only draws the capsules, so without it, touches in the tray's margins
/// fall through to the rows visible behind the bar (see
/// `TabBarTrayShield.swift`).
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
/// window is created, so it is settled before the Mail tab's `MailRootView`
/// can appear and land.
struct CompactSectionTabs: View {
    @Environment(SceneNavigator.self) private var navigator

    /// The tab bar's selection, through the navigator so a switch notes the
    /// section on the resume session.
    private var tab: Binding<CompactTab> {
        Binding(get: { navigator.compactTab }, set: { navigator.showTab($0) })
    }

    var body: some View {
        TabView(selection: tab) {
            Tab("Mail", systemImage: "tray", value: CompactTab.mail) {
                MailRootView()
                    .tabBarTrayShield()
            }
            Tab("Feeds", systemImage: "dot.radiowaves.up.forward", value: CompactTab.feeds) {
                FeedRootView()
                    .tabBarTrayShield()
            }
            Tab("Addresses", systemImage: "at", value: CompactTab.addresses) {
                AddressManagementTab()
                    .tabBarTrayShield()
            }
            Tab("Settings", systemImage: "gear", value: CompactTab.settings) {
                SettingsView()
                    .tabBarTrayShield()
            }
            // The search role detaches to the bottom-right, next to the tab bar.
            // On iOS 26 it adopts the morph (tab bar collapses to a dismiss
            // button, the button expands into a focused field); on iOS 18–25
            // it's a plain search tab. The morph itself comes from the
            // `.searchable` inside `SearchView`.
            Tab(value: CompactTab.search, role: .search) {
                SearchView()
                    .tabBarTrayShield()
            }
        }
        .environment(\.showsCompactBrandMark, true)
        // The same section, for the menus that share a chord across mail and
        // feeds (`SharedChordPolicy`): each tab keeps its selection while the
        // other is in front, so the section is what decides between them.
        .reportsActiveSection(navigator.compactTab.resumeSection)
    }
}
#endif

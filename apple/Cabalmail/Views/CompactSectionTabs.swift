import SwiftUI
import CabalmailKit

/// Compact tab identities. `resumeSection` maps the two content tabs onto
/// the resume session's sections; the utility tabs have none.
enum CompactTab: Hashable {
    case mail, feeds, addresses, settings, search

    var resumeSection: ResumeSession.Section? {
        switch self {
        case .mail: return .mail
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
/// Its own view rather than a computed property of `SignedInRootView`, so
/// that the tab selection is `@State` on a view created afresh each time the
/// tab tree is built. `SignedInRootView` itself survives a size-class swap
/// between this tree and the regular split (the swap replaces only the
/// subtree), so a selection stored there went stale: close an iPhone Duo, or
/// narrow an iPad window, after reading feeds in the split, and the tab bar
/// came back on whichever tab it had last shown while the resume session —
/// kept live by the split's `recordFolder` / `recordFeedScope` — said Feeds.
/// Seeding the state in `init` from the live coordinator re-reads the truth
/// at every rebuild (SwiftUI honours a `State` initial value only when the
/// view's identity is new, which is exactly then), and it settles the tab
/// before the Mail tab's `MailRootView` can appear and record a mail landing
/// over the feeds section (#1644).
struct CompactSectionTabs: View {
    @Environment(AppState.self) private var appState
    @State private var tab: CompactTab

    /// - Parameter initialSection: the section to open on — the coordinator's
    ///   `launchSection` when one exists, else the stored session's (a
    ///   `@State` default can't reach the environment, hence the caller
    ///   passes it in — see `ResumeSessionStore.storedSection`).
    init(initialSection: ResumeSession.Section?) {
        _tab = State(initialValue: CompactTab.initial(for: initialSection))
    }

    var body: some View {
        TabView(selection: $tab) {
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
        // The resume session remembers which section the user was in; the
        // Mail and Feeds tabs each keep their own position, so only the
        // section moves here. Other tabs leave it alone.
        .onChange(of: tab) { _, tab in
            if let section = tab.resumeSection {
                appState.navCoordinator?.noteSection(section)
            }
        }
    }
}
#endif

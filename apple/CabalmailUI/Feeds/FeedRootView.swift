import SwiftUI
import CabalmailKit

/// Root of the Feeds tab on iPhone (compact) and visionOS: its own
/// three-column split that collapses to a stack on compact, mirroring
/// `MailRootView`'s shape without its mail-specific plumbing. On macOS and
/// regular iPad the feeds live in the mail sidebar instead (see
/// `FolderListView`'s Feeds section), so this view is never mounted there.
///
/// The scope, the open item and the collapsed column are the window's
/// (`SceneNavigator`), so a layout swap keeps them. The window's first feed
/// tree reopens the scope and item the resume session recorded; every
/// selection change is recorded back, so a relaunch reopens the same list —
/// or the same item, at the same place (`FeedItemDetailView` handles the
/// scroll position).
struct FeedRootView: View {
    @Environment(SceneNavigator.self) private var navigator
    /// This view's identity as one of the window's feed trees
    /// (`SceneNavigator.feedTreeAppeared`).
    @State private var tree = UUID()

    private var selectedScope: RssItemScope? { navigator.feeds.scope(in: tree) }
    private var selectedItem: RssItem? { navigator.feeds.item(in: tree) }

    private var scopeSelection: Binding<RssItemScope?> {
        Binding(get: { selectedScope }, set: { navigator.selectFeedScope($0) })
    }

    private var itemSelection: Binding<RssItem?> {
        Binding(get: { selectedItem }, set: { navigator.selectFeedItem($0, from: tree) })
    }

    private var columnSelection: Binding<NavigationSplitViewColumn> {
        Binding(get: { navigator.feeds.column(in: tree) }, set: { navigator.setFeedColumn($0, from: tree) })
    }

    var body: some View {
        NavigationSplitView(preferredCompactColumn: columnSelection) {
            FeedSidebarList(selection: scopeSelection)
        } content: {
            if let selectedScope {
                // A pick from the list's scope-switch menu lands on the same
                // state a sidebar tap does, so the sidebar highlight and the
                // resume record follow it.
                FeedItemListView(scope: selectedScope, selection: itemSelection,
                                 onSwitchScope: { navigator.selectFeedScope($0) })
                    .id(selectedScope)
                    // A parked item (the launch restore, a tapped feed banner,
                    // a layout swap's hand-off) is applied by the list itself,
                    // once it is on screen and loaded. See `FeedItemListView`
                    // and #1664.
            } else {
                ContentUnavailableView("Select a feed", systemImage: "sidebar.left",
                                       description: Text("Pick a feed or folder from the sidebar."))
            }
        } detail: {
            if let selectedItem {
                FeedItemDetailView(item: selectedItem)
                    .id(selectedItem.id)
            } else {
                ContentUnavailableView("No item selected", systemImage: "doc.text",
                                       description: Text("Pick an item from the list to read it."))
            }
        }
        // What the Feeds menu's item commands can act on (the iPadOS
        // hardware-keyboard menu reaches this tab); the section itself is
        // the tab bar's to report.
        .reportsFeedMenuAvailability(
            selectedCount: selectedItem == nil ? 0 : 1,
            hasOpenItem: selectedItem != nil,
            hasScope: selectedScope != nil
        )
        // The window's first feed landing, or a layout swap's hand-off.
        .task { await navigator.feedTreeAppeared(tree) }
    }
}

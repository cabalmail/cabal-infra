import SwiftUI
import CabalmailKit

/// Root of the Feeds tab on iPhone (compact) and visionOS: its own
/// three-column split that collapses to a stack on compact, mirroring
/// `MailRootView`'s shape without its mail-specific plumbing. On macOS and
/// regular iPad the feeds live in the mail sidebar instead (see
/// `FolderListView`'s Feeds section), so this view is never mounted there.
struct FeedRootView: View {
    @State private var selectedScope: RssItemScope?
    @State private var selectedItem: RssItem?
    @State private var compactColumn: NavigationSplitViewColumn = .sidebar
    @Environment(AppState.self) private var appState

    var body: some View {
        NavigationSplitView(preferredCompactColumn: $compactColumn) {
            FeedSidebarList(selection: $selectedScope)
        } content: {
            if let selectedScope {
                FeedItemListView(scope: selectedScope, selection: $selectedItem)
                    .id(selectedScope)
            } else {
                ContentUnavailableView("Select a feed", systemImage: "sidebar.left",
                                       description: Text("Pick a feed or folder from the sidebar."))
            }
        } detail: {
            if let selectedItem {
                FeedItemDetailView(item: selectedItem, subscription: subscription(for: selectedItem))
                    .id(selectedItem.id)
            } else {
                ContentUnavailableView("No item selected", systemImage: "doc.text",
                                       description: Text("Pick an item from the list to read it."))
            }
        }
        .onChange(of: selectedScope) { _, scope in
            selectedItem = nil
            compactColumn = scope == nil ? .sidebar : .content
        }
        .onChange(of: selectedItem) { _, item in
            compactColumn = CompactColumnPolicy.column(hasSelectedMessage: item != nil, current: compactColumn)
        }
        .onChange(of: compactColumn) { _, column in
            if column != .detail, selectedItem != nil { selectedItem = nil }
        }
        .task(id: selectedItem?.subscriptionId) { await resolveSubscription() }
    }

    @State private var resolved: RssSubscription?

    private func subscription(for item: RssItem) -> RssSubscription? {
        resolved?.subscriptionId == item.subscriptionId ? resolved : nil
    }

    private func resolveSubscription() async {
        guard let id = selectedItem?.subscriptionId, let store = appState.client?.rssStore else {
            resolved = nil
            return
        }
        resolved = try? await store.subscription(id: id)
    }
}

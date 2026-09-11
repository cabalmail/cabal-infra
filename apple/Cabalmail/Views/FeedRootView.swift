import SwiftUI
import CabalmailKit

/// Root of the Feeds tab on iPhone (compact) and visionOS: its own
/// three-column split that collapses to a stack on compact, mirroring
/// `MailRootView`'s shape without its mail-specific plumbing. On macOS and
/// regular iPad the feeds live in the mail sidebar instead (see
/// `FolderListView`'s Feeds section), so this view is never mounted there.
///
/// Restores the scope and item the resume session recorded the first time it
/// appears in a process, and records every selection change back, so a
/// relaunch reopens the same list — or the same item, at the same place
/// (`FeedItemDetailView` handles the scroll position).
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
            // A launch restore parks the item to reopen under this scope;
            // consuming it here — after the scope change landed — is what
            // keeps this very handler from clearing it. Jump straight to
            // `.detail` in that case so the column handler below never sees
            // an intermediate `.content` and drops the item again.
            let restored = scope.flatMap { appState.navCoordinator?.consumeFeedItemRestore(for: $0) }
            selectedItem = restored
            if scope == nil {
                compactColumn = .sidebar
            } else {
                compactColumn = restored == nil ? .content : .detail
            }
            appState.navCoordinator?.recordFeedScope(scope)
        }
        .onChange(of: selectedItem) { _, item in
            compactColumn = CompactColumnPolicy.column(hasSelectedMessage: item != nil, current: compactColumn)
            appState.navCoordinator?.recordFeedItem(item)
        }
        .onChange(of: compactColumn) { _, column in
            if column != .detail, selectedItem != nil { selectedItem = nil }
        }
        .task(id: selectedItem?.subscriptionId) { await resolveSubscription() }
        .task {
            // Once per process (the coordinator guards it): reopen the scope
            // the session ended in. The item, if still in the store, is
            // parked for the scope handler above.
            guard selectedScope == nil,
                  let scope = await appState.navCoordinator?.consumeFeedsLaunchTarget()
            else { return }
            selectedScope = scope
        }
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

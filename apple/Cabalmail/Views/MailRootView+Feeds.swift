import SwiftUI
import CabalmailKit

// The feed reader's plumbing in the wide split view (RSS plan, phase 5b),
// lifted into a sibling extension so `MailRootView`'s body stays under the
// lint caps - the same arrangement as its search and sidebar chrome.
extension MailRootView {
    /// The Feeds section's selection: a pick clears the mail selection so the
    /// content and detail columns swap to the item list and reader; a mail
    /// folder pick (`sidebarSelection`) clears this in turn.
    var feedSidebarSelection: Binding<RssItemScope?> {
        Binding(
            get: { selectedFeedScope },
            set: { picked in
                if picked != nil {
                    if isSearching { endGlobalSearch() }
                    dismissFolderPanel()
                    selectedFolder = nil
                    selectedEnvelope = nil
                    crossFolderDetail = nil
                    listSelectionCount = 0
                }
                selectedFeedScope = picked
            }
        )
    }

    /// Content column: the feed item list while a feed scope is selected,
    /// else the mail column (search results or the selected folder).
    @ViewBuilder
    var contentColumn: some View {
        if let selectedFeedScope, !isSearching {
            FeedItemListView(scope: selectedFeedScope, selection: $selectedFeedItem)
                .id(selectedFeedScope)
        } else {
            mailContentColumn
        }
    }

    /// Detail column: the feed reader while a feed scope is selected, else
    /// the mail reader / multi-selection / empty prompts.
    var detailColumn: some View {
        Group {
            if selectedFeedScope != nil, !isSearching {
                feedDetailPane
            } else if listSelectionCount >= 2 {
                // Multi-selection: no single message to read, so mirror Mail's
                // "N Messages Selected" pane. Bulk actions live in the action
                // bar beneath the message list.
                ContentUnavailableView(
                    "\(listSelectionCount) Messages Selected",
                    systemImage: "envelope.badge",
                    description: Text("Use the action bar below the list to act on them together.")
                )
                #if os(macOS)
                .toolbar { EmptyDetailToolbar() }
                #endif
            } else if let folder = detailFolder, let selectedEnvelope {
                MessageDetailView(
                    folder: folder,
                    envelope: selectedEnvelope
                )
                .id("\(folder.path)#\(selectedEnvelope.uid)")
            } else {
                ContentUnavailableView(
                    "No message selected",
                    systemImage: "envelope",
                    description: Text("Pick a message from the list to read it.")
                )
                #if os(macOS)
                // Reserve the detail column's toolbar slots with disabled
                // stand-ins so the message-list toolbar (compose, reload)
                // stays anchored above the list pane. Without these,
                // NavigationSplitView's unified toolbar packs the list
                // items at the trailing edge — visually above the empty
                // detail pane — until a message is picked and the real
                // detail toolbar shoves them back into place.
                .toolbar { EmptyDetailToolbar() }
                #endif
            }
        }
    }

    func feedNavigation() -> FeedNavigationModifier {
        FeedNavigationModifier(
            selectedFeedScope: $selectedFeedScope, selectedFeedItem: $selectedFeedItem,
            selectedFeedSubscription: $selectedFeedSubscription, compactColumn: $compactColumn
        )
    }

    /// Slide the iPad-regular folder panel away after a pick, so the message
    /// list is fully interactive again. One routine, two callers: the sidebar
    /// binding (a user pick) and the folder-change handler (a programmatic
    /// one). No-op on compact — the panel is never presented there — and on
    /// launches, where INBOX auto-selects with the panel already closed.
    func dismissFolderPanel() {
        #if os(iOS)
        withAnimation(folderPanelAnimation) { folderPanelPresented = false }
        #endif
    }

    /// End the global search exactly the way the search field's own × does
    /// (`GlobalSearchField`): zero the query and drop focus, and let the
    /// mounted search list's `onChange(of: searchQuery)` call `clearSearch()`
    /// from there. One routine rather than a second copy of the rule — the ×
    /// path already lands the user back on a folder, which is what the folder
    /// pick wanted all along.
    func endGlobalSearch() {
        searchModel?.searchQuery = ""
        searchFieldFocused = false
    }

    /// Detail column while a feed scope is selected: the reader, or the
    /// "pick an item" prompt.
    @ViewBuilder
    var feedDetailPane: some View {
        if let selectedFeedItem {
            FeedItemDetailView(item: selectedFeedItem, subscription: selectedFeedSubscription)
                .id(selectedFeedItem.id)
        } else {
            ContentUnavailableView(
                "No item selected",
                systemImage: "doc.text",
                description: Text("Pick an item from the list to read it.")
            )
            #if os(macOS)
            .toolbar { EmptyDetailToolbar() }
            #endif
        }
    }
}

/// Feed navigation state transitions: a scope shows its list, an item
/// pushes the reader on compact and pops it when the column falls back, and
/// the reader is handed the item's subscription (per-feed preferences and
/// web-view storage) as soon as it is known.
struct FeedNavigationModifier: ViewModifier {
    @Binding var selectedFeedScope: RssItemScope?
    @Binding var selectedFeedItem: RssItem?
    @Binding var selectedFeedSubscription: RssSubscription?
    @Binding var compactColumn: NavigationSplitViewColumn
    @Environment(AppState.self) private var appState

    func body(content: Content) -> some View {
        content
            .onChange(of: selectedFeedScope) { _, scope in
                selectedFeedItem = nil
                if scope != nil { compactColumn = .content }
            }
            .onChange(of: selectedFeedItem) { _, item in
                compactColumn = CompactColumnPolicy.column(hasSelectedMessage: item != nil, current: compactColumn)
            }
            .onChange(of: compactColumn) { _, column in
                if column != .detail, selectedFeedItem != nil { selectedFeedItem = nil }
            }
            .task(id: selectedFeedItem?.subscriptionId) {
                guard let id = selectedFeedItem?.subscriptionId, let store = appState.client?.rssStore else {
                    selectedFeedSubscription = nil
                    return
                }
                selectedFeedSubscription = try? await store.subscription(id: id)
            }
    }
}

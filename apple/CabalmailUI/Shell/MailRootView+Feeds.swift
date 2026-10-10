import SwiftUI
import CabalmailKit

// The feed reader's plumbing in the wide split view (RSS plan, phase 5b),
// lifted into a sibling extension so `MailRootView`'s body stays under the
// lint caps - the same arrangement as its search and sidebar chrome.
extension MailRootView {
    /// The wide split's feed list (RSS plan, phase 5): the window's, while
    /// it is in the feeds section (`SceneNavigator.splitShowsFeeds`), and
    /// mutually exclusive with the mail folder there. The compact layout
    /// shows feeds in their own tab instead.
    var selectedFeedScope: RssItemScope? {
        isWideSidebar && navigator.splitShowsFeeds ? navigator.feeds.scope(in: tree) : nil
    }

    var selectedFeedItem: RssItem? {
        selectedFeedScope == nil ? nil : navigator.feeds.item(in: tree)
    }

    /// The Feeds section's selection: a pick clears the mail selection so the
    /// content and detail columns swap to the item list and reader; a mail
    /// folder pick (`sidebarSelection`) clears this in turn.
    var feedSidebarSelection: Binding<RssItemScope?> {
        Binding(
            get: { selectedFeedScope },
            set: { picked in
                if picked != nil { feedListOpened(endingSearch: true) }
                navigator.showFeeds(picked)
            }
        )
    }

    /// The item list's selection, through the navigator.
    var feedItemSelection: Binding<RssItem?> {
        Binding(get: { selectedFeedItem }, set: { navigator.selectFeedItem($0, from: tree) })
    }

    /// The view's half of opening a feed list: the folder panel closes and
    /// the mail multi-selection goes. A pick or a tapped feed banner also
    /// ends a search, as the search field's × does; a landing or a layout
    /// swap's hand-off leaves it on screen (#1654).
    func feedListOpened(endingSearch: Bool) {
        if endingSearch, isSearching { endGlobalSearch() }
        dismissFolderPanel()
        listSelectionCount = 0
    }

    /// The feed list for the content column (`MailContentColumn`) while a
    /// feed scope is selected. A pick from the list's scope-switch menu goes
    /// through the same binding as a sidebar tap, so it clears the mail
    /// selection and records the resume session the same way.
    var feedListSelection: FeedListSelection? {
        selectedFeedScope.map {
            FeedListSelection(
                scope: $0,
                selection: feedItemSelection,
                onSwitchScope: { feedSidebarSelection.wrappedValue = $0 }
            )
        }
    }

    /// Detail column: the feed reader while a feed scope is selected, else
    /// the mail reader / multi-selection / empty prompts.
    var detailColumn: some View {
        Group {
            if selectedFeedScope != nil, !isSearching {
                FeedReaderColumn(item: selectedFeedItem, placeholderChrome: feedPlaceholderChrome)
            } else {
                MailReaderColumn(
                    selectionCount: listSelectionCount,
                    envelope: selectedEnvelope,
                    sidebarFolder: selectedFolder,
                    placeholderChrome: mailPlaceholderChrome
                )
            }
        }
    }

    #if os(macOS)
    // Reserve the detail column's toolbar slots with disabled stand-ins while
    // it shows a placeholder, so the message-list toolbar (compose, reload)
    // stays anchored above the list pane. Without these, NavigationSplitView's
    // unified toolbar packs the list items at the trailing edge — visually
    // above the empty detail pane — until a message is picked and the real
    // detail toolbar shoves them back into place.
    private var mailPlaceholderChrome: ReaderPlaceholderToolbar<EmptyDetailToolbar> {
        ReaderPlaceholderToolbar(items: EmptyDetailToolbar())
    }

    private var feedPlaceholderChrome: ReaderPlaceholderToolbar<EmptyFeedDetailToolbar> {
        ReaderPlaceholderToolbar(items: EmptyFeedDetailToolbar())
    }
    #else
    private var mailPlaceholderChrome: EmptyModifier { EmptyModifier() }
    private var feedPlaceholderChrome: EmptyModifier { EmptyModifier() }
    #endif

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
}

import SwiftUI
import CabalmailKit

/// A feed list open in a wide shell's content column: the scope, the item
/// selection, and what a pick from the list's scope-switch menu does.
struct FeedListSelection {
    let scope: RssItemScope
    let selection: Binding<RssItem?>
    let onSwitchScope: (RssItemScope) -> Void
}

/// The content column every mail shell shows: a header slot, then the feed
/// item list, the window's search results, the folder's message list, or the
/// "Select a folder" prompt.
///
/// What differs by shell comes in as values: the header is where the split
/// hosts its search field (`GlobalSearchFieldPlacement`), and the feed list
/// and the search model are optional, so a shell that passes neither can
/// only ever show a folder. The precedence between the search and the folder
/// is `ContentColumnPolicy`'s, beside the rule a folder pick has to satisfy
/// against it (#1217).
struct MailContentColumn<Header: View>: View {
    /// The feed list, when a wide shell is in its feeds section.
    var feedList: FeedListSelection?
    /// The window's search model, for a shell that hosts the search field.
    var search: MessageListViewModel?
    /// Whether the search field is engaged, so its results take the column.
    var isSearching = false
    /// The folder whose messages the column lists.
    let folder: Folder?
    /// The open message.
    let selection: Binding<Envelope?>
    /// How many messages the list has selected (`MessageListView`).
    let onSelectionCountChanged: (Int) -> Void
    /// A pick from the list's folder-switch menu.
    let onSwitchFolder: (Folder) -> Void
    /// The measured width of the Mac's title-switch menu at the leading edge
    /// of the column's toolbar section, which the toolbar search field is
    /// sized around (`ToolbarSearchFieldWidth`).
    var onLeadingToolbarWidthChanged: (CGFloat) -> Void = { _ in }
    @ViewBuilder let header: () -> Header

    var body: some View {
        VStack(spacing: 0) {
            header()
            list
        }
    }

    @ViewBuilder
    private var list: some View {
        if let feedList, !isSearching {
            FeedItemListView(
                scope: feedList.scope,
                selection: feedList.selection,
                onSwitchScope: feedList.onSwitchScope,
                onScopeMenuWidthChanged: onLeadingToolbarWidthChanged
            )
            .id(feedList.scope)
        } else {
            switch ContentColumnPolicy.mode(isSearching: isSearching, selectedFolderPath: folder?.path) {
            case .search:
                if let search {
                    // Global search owns the column while its field is
                    // engaged. Stable `.id` so it isn't torn down per
                    // keystroke; the reader still opens each result against
                    // its true mailbox (`MailReaderChoice`).
                    MessageListView(
                        scope: .search,
                        injectedSearchModel: search,
                        selection: selection,
                        onSelectionCountChanged: onSelectionCountChanged
                    )
                    .id("search")
                }
            case .folder:
                if let folder {
                    MessageListView(
                        scope: .folder(folder),
                        selection: selection,
                        onSelectionCountChanged: onSelectionCountChanged,
                        onSwitchFolder: onSwitchFolder,
                        onFolderMenuWidthChanged: onLeadingToolbarWidthChanged
                    )
                    .id(folder.path)
                }
            case .empty:
                ContentUnavailableView(
                    "Select a folder",
                    systemImage: "sidebar.left",
                    description: Text("Pick a folder from the sidebar to browse messages.")
                )
            }
        }
    }
}

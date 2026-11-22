import SwiftUI
import CabalmailKit

/// The mail sidebar's list, and its selection.
///
/// The list selects a `SidebarSelection`, so a row tagged with a mail folder
/// and, where the layout allows it, a row tagged with a feed list are both
/// rows it selects. What it reads and writes is still the window's own pair,
/// the mail folder and the feed list, through `SidebarListSelection`.
///
/// The rows are built by the caller, in its own body, and tagged there
/// with `sidebarFolderRow(_:)` and, where
/// `HostPlatform.sidebarSelectsFeeds` says the list selects feeds, with
/// `sidebarFeedRow(_:)`. A row with neither is not selectable: a section's
/// filter pills, a hint, a feed row drawn as a button.
struct SidebarSelectionList<Rows: View>: View {
    @Binding private var folder: Folder?
    private let feedScope: Binding<RssItemScope?>?
    private let folders: [Folder]
    private let rows: Rows

    /// - Parameters:
    ///   - folder: the window's mail folder.
    ///   - feedScope: the window's feed list, on the layouts where feeds
    ///     share this sidebar; nil elsewhere.
    ///   - folders: the fetched folders the rows are drawn from, which a
    ///     pick resolves its path against.
    init(
        folder: Binding<Folder?>, feedScope: Binding<RssItemScope?>?, folders: [Folder],
        @ViewBuilder rows: () -> Rows
    ) {
        _folder = folder
        self.feedScope = feedScope
        self.folders = folders
        self.rows = rows()
    }

    var body: some View {
        List(selection: selection) { rows }
    }

    private var selection: Binding<SidebarSelection?> {
        let folders = folders
        return SidebarListSelection(selectsFeeds: HostPlatform.current.sidebarSelectsFeeds)
            .binding(folder: $folder, feedScope: feedScope, folders: { folders })
    }
}

extension View {
    /// Makes this the row `SidebarSelectionList` selects for `folder`.
    func sidebarFolderRow(_ folder: Folder) -> some View {
        tag(SidebarSelection.mailFolder(path: folder.path))
    }

    /// Makes this the row `SidebarSelectionList` selects for the feed list
    /// `scope`.
    func sidebarFeedRow(_ scope: RssItemScope) -> some View {
        tag(SidebarSelection.feedScope(scope))
    }
}

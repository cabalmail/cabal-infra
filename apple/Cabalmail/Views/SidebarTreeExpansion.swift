import Foundation
import CabalmailKit

/// The Expand all / Collapse all affordances' arithmetic for the two sidebar
/// trees. Each tree persists the set of *collapsed* nodes, so "expand all"
/// is the empty set and "collapse all" is every node that has something to
/// hide. Pure, so the two rules and the "nothing to do" gate are testable.
enum SidebarTreeExpansion {
    /// Mail folders with at least one child in the sidebar's list. The
    /// buttons are disabled when this is empty: a flat mailbox has nothing
    /// to expand or collapse.
    static func collapsibleFolderPaths(_ folders: [Folder]) -> Set<String> {
        Set(folders.filter { FolderTree.hasChildren($0, in: folders) }.map(\.path))
    }

    /// Feed folders that hold a child folder or a subscription — the ones
    /// `FeedSidebarRows` draws with a live chevron.
    static func collapsibleFeedFolderIds(
        folders: [RssFolder],
        subscriptions: [RssSubscription]
    ) -> Set<String> {
        let parents = Set(folders.map(\.parentFolderId))
        let holders = Set(subscriptions.map(\.folderId))
        return Set(folders.map(\.folderId).filter { parents.contains($0) || holders.contains($0) })
    }

    /// The collapsed set after the affordance: everything collapsible, or
    /// nothing.
    static func collapsed(all collapsible: Set<String>, collapse: Bool) -> Set<String> {
        collapse ? collapsible : []
    }
}

/// A menu-bar request to expand or collapse one of the sidebar trees, routed
/// through `AppState.requestSidebarTree(_:)` the way the Message and Feeds
/// menus route theirs — so it works whichever pane has focus. The mounted
/// sidebar that owns the named tree answers it; the other ignores it.
enum SidebarTreeCommand: Equatable {
    case expandAllFolders
    case collapseAllFolders
    case expandAllFeedFolders
    case collapseAllFeedFolders

    var isMail: Bool { self == .expandAllFolders || self == .collapseAllFolders }
    var collapses: Bool { self == .collapseAllFolders || self == .collapseAllFeedFolders }
}

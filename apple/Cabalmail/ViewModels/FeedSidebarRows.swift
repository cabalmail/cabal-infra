import Foundation
import CabalmailKit

/// One drawable row of the Feeds sidebar section: a folder or a subscription,
/// with the depth and disclosure state the row needs to draw itself.
struct FeedSidebarRow: Identifiable, Equatable {
    enum Kind: Equatable {
        case folder(RssFolder)
        case subscription(RssSubscription)
    }

    let kind: Kind
    /// Indentation steps — one per ancestor folder.
    let depth: Int
    /// For folders: whether the row has children its chevron can hide.
    let hasChildren: Bool
    /// Unread items under this row (a folder sums its descendants).
    let unread: Int

    var id: String {
        switch kind {
        case .folder(let folder): return "folder:\(folder.folderId)"
        case .subscription(let sub): return "sub:\(sub.subscriptionId)"
        }
    }

    var scope: RssItemScope {
        switch kind {
        case .folder(let folder): return .folder(folder.folderId)
        case .subscription(let sub): return .subscription(sub.subscriptionId)
        }
    }

    var title: String {
        switch kind {
        case .folder(let folder): return folder.name
        case .subscription(let sub): return sub.displayTitle
        }
    }
}

/// Turns the catalog into sidebar rows: folders by `displayOrder` then name,
/// each folder's subscriptions after its child folders, root subscriptions
/// last. Pure, so the tree rules are testable without standing up a `List`.
enum FeedSidebarRows {
    /// The "All Feeds" row that heads the list: every subscription's items in
    /// one scope, with the total unread as its count.
    ///
    /// A row rather than a bespoke `Label` because both sidebars draw it
    /// through `FeedSidebarRowLabel`, which is what gives it the accent icon
    /// and the capsule count its siblings have. The compact Feeds tab used to
    /// hand-build it and came out the only row in the list drawn differently
    /// on both axes (#1548), so the shape lives here and neither layout owns
    /// a copy. Its identity is a folder with an empty id: `RssItemScope.all`
    /// is what selects it, so the id is never asked for a folder's items.
    static func allFeedsRow(unread: Int) -> FeedSidebarRow {
        FeedSidebarRow(kind: .folder(RssFolder(folderId: "", name: "All Feeds")),
                       depth: 0, hasChildren: false, unread: unread)
    }

    static func rows(
        folders: [RssFolder],
        subscriptions: [RssSubscription],
        unreadCounts: [String: Int],
        collapsed: Set<String>,
        filter: String = ""
    ) -> [FeedSidebarRow] {
        let needle = filter.trimmingCharacters(in: .whitespaces).lowercased()
        let foldersByParent = Dictionary(grouping: folders, by: \.parentFolderId)
        let subsByFolder = Dictionary(grouping: subscriptions, by: \.folderId)
        var out: [FeedSidebarRow] = []
        func matches(_ sub: RssSubscription) -> Bool {
            needle.isEmpty || sub.displayTitle.lowercased().contains(needle)
        }
        func unreadUnder(_ folderId: String) -> Int {
            let own = (subsByFolder[folderId] ?? []).reduce(0) { $0 + (unreadCounts[$1.subscriptionId] ?? 0) }
            return own + (foldersByParent[folderId] ?? []).reduce(0) { $0 + unreadUnder($1.folderId) }
        }
        func visit(_ parentId: String, depth: Int) {
            let children = (foldersByParent[parentId] ?? []).sorted {
                ($0.displayOrder, $0.name.lowercased()) < ($1.displayOrder, $1.name.lowercased())
            }
            for folder in children {
                let subs = (subsByFolder[folder.folderId] ?? []).filter(matches)
                let hasChildren = !(foldersByParent[folder.folderId] ?? []).isEmpty || !subs.isEmpty
                // While filtering, a folder shows only if something under it matches.
                if !needle.isEmpty && !hasMatch(under: folder.folderId) { continue }
                out.append(FeedSidebarRow(kind: .folder(folder), depth: depth, hasChildren: hasChildren,
                                          unread: unreadUnder(folder.folderId)))
                if collapsed.contains(folder.folderId) && needle.isEmpty { continue }
                visit(folder.folderId, depth: depth + 1)
                for sub in subs.sorted(by: { $0.displayTitle.lowercased() < $1.displayTitle.lowercased() }) {
                    out.append(FeedSidebarRow(kind: .subscription(sub), depth: depth + 1, hasChildren: false,
                                              unread: unreadCounts[sub.subscriptionId] ?? 0))
                }
            }
        }
        func hasMatch(under folderId: String) -> Bool {
            if (subsByFolder[folderId] ?? []).contains(where: matches) { return true }
            return (foldersByParent[folderId] ?? []).contains { hasMatch(under: $0.folderId) }
        }
        visit("", depth: 0)
        for sub in (subsByFolder[""] ?? []).filter(matches)
            .sorted(by: { $0.displayTitle.lowercased() < $1.displayTitle.lowercased() }) {
            out.append(FeedSidebarRow(kind: .subscription(sub), depth: 0, hasChildren: false,
                                      unread: unreadCounts[sub.subscriptionId] ?? 0))
        }
        return out
    }

    /// Total unread across the catalog (the section header's badge).
    static func totalUnread(_ unreadCounts: [String: Int]) -> Int {
        unreadCounts.values.reduce(0, +)
    }
}

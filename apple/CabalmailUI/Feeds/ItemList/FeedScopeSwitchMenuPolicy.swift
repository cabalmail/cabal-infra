import Foundation
import CabalmailKit

/// What the feed list's scope-switch menu offers — the menu behind the scope
/// name at the top of the item list — and the identity SwiftUI needs to
/// redraw it. The feed sibling of `FolderSwitchMenuPolicy`, built on the
/// same `ReaderMenuRow` rows so the two menus share their assistive
/// behaviour (#1367) and the macOS materialize-once handling (#1329, #1337).
///
/// One flat list: "All Feeds" first, then the folder tree flattened
/// depth-first in the sidebar's own order (`FeedSidebarRows`), each folder
/// followed by its subscriptions, with the row indented one step per level
/// of nesting. A menu row cannot carry leading padding on every platform (an
/// AppKit menu item is a title string), so the indentation is em spaces in
/// the label itself — which is also what an assistive client reads, so a
/// nested feed is announced with its nesting.
///
/// Pure, for the reason `FolderSwitchMenuPolicy` is: the rows can be tested
/// directly, and the macOS menu identity is built from the rows the menu
/// draws, so the two can never disagree.
enum FeedScopeSwitchMenuPolicy {
    static let allFeedsLabel = "All Feeds"

    /// One indentation step: an em space, the width of the type size.
    static let indentUnit = "\u{2003}"

    /// The rows the menu offers for the catalog, with `current` checked.
    ///
    /// Until the catalog arrives (or if `current` is somehow not in it) the
    /// menu still shows the scope the list is on, checked, under All Feeds,
    /// so the affordance never reads as empty; `currentTitle` is that row's
    /// label, since a scope alone carries no name.
    static func rows(
        folders: [RssFolder],
        subscriptions: [RssSubscription],
        current: RssItemScope,
        currentTitle: String
    ) -> [ReaderMenuRow<RssItemScope>] {
        let tree = FeedSidebarRows.rows(folders: folders, subscriptions: subscriptions,
                                        unreadCounts: [:], collapsed: [])
        var rows = [row(.all, title: allFeedsLabel, depth: 0, current: current)]
        if current != .all, !tree.contains(where: { $0.scope == current }) {
            rows.append(row(current, title: currentTitle, depth: 0, current: current))
        }
        rows += tree.map { row($0.scope, title: $0.title, depth: $0.depth, current: current) }
        return rows
    }

    /// The row's title, indented one step per level of nesting.
    static func label(title: String, depth: Int) -> String {
        String(repeating: indentUnit, count: max(0, depth)) + title
    }

    /// The row's glyph: the sidebar's, so the menu reads like the tree it
    /// flattens (All Feeds is drawn as a folder there too, #1548).
    static func symbol(for scope: RssItemScope) -> String {
        switch scope {
        case .all, .folder: return "folder"
        case .subscription: return "dot.radiowaves.up.forward"
        }
    }

    /// Identity for the macOS `Menu`, covering everything the rows draw.
    static func identity(_ rows: [ReaderMenuRow<RssItemScope>]) -> String {
        ReaderOptionMenuPolicy.identity(rows)
    }

    private static func row(
        _ scope: RssItemScope,
        title: String,
        depth: Int,
        current: RssItemScope
    ) -> ReaderMenuRow<RssItemScope> {
        ReaderMenuRow(
            option: scope,
            key: "scope.\(scope.token)",
            label: label(title: title, depth: depth),
            isOn: scope == current
        )
    }
}

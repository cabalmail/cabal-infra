import Foundation

/// The feed sidebar's filter: every subscription, or only the ones with
/// unread items. Sticky per device (`@AppStorage`), never synced — the same
/// reasoning as `FolderListFilter`.
///
/// One Unread pill that toggles, not an All / Unread pair: feeds have no
/// subscription axis (every feed in the list is one), so there is nothing to
/// combine Unread with, and an All pill only restated "Unread off". The two
/// cases stay as the stored form (`cabalmail.feeds.filter`). The rows
/// themselves come from `FeedSidebarRows`, which takes `unreadOnly` and the
/// open scope to keep.
enum FeedListFilter: String {
    case all, unread

    /// A fresh install opens on Unread: the feed reader's job is to show
    /// what is new, and the `All Feeds` row keeps the whole catalog one tap
    /// away.
    static let defaultForFeeds: FeedListFilter = .unread

    /// The one pill's label.
    static let pillLabel = "Unread"

    var unreadOnly: Bool { self == .unread }

    /// The state after tapping the pill.
    var toggled: FeedListFilter { unreadOnly ? .all : .unread }
}

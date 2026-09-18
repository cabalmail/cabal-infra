import Foundation

/// The feed sidebar's filter: every subscription, or only the ones with
/// unread items. Sticky per device (`@AppStorage`), never synced — the same
/// reasoning as `FolderListFilter`.
///
/// A radio rather than `FolderListFilter`'s toggles: feeds have no
/// subscription axis (every feed in the list is one), so there is nothing to
/// combine Unread with. The rows themselves come from `FeedSidebarRows`,
/// which takes the filter's `unreadOnly` and the open scope to keep.
enum FeedListFilter: String, CaseIterable, Identifiable {
    case all, unread

    var id: String { rawValue }

    /// A fresh install opens on Unread: the feed reader's job is to show
    /// what is new, and the `All Feeds` row keeps the whole catalog one tap
    /// away.
    static let defaultForFeeds: FeedListFilter = .unread

    var label: String {
        switch self {
        case .all:    return "All"
        case .unread: return "Unread"
        }
    }

    var unreadOnly: Bool { self == .unread }
}

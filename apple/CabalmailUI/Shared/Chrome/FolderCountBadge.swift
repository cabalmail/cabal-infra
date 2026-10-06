import Foundation
import CabalmailKit

/// What a sidebar count badge shows under the user's `folderCountDisplay`
/// preference. One rule for both media: the mail folder rows
/// (`FolderListView.countBadgeText`) and the feed rows
/// (`FeedSidebarRowLabel`) read it, so "Unread / total" means the same
/// thing on a folder and on a feed (cross-media plan, Phase 1).
///
/// `nil` means "draw no badge" — the capsule collapses rather than showing a
/// stray `0` on a caught-up folder. The counts are optionals because a mail
/// folder's STATUS may not have arrived yet; a feed's counts come from the
/// local cache and are always known (absent = zero).
enum FolderCountBadge {
    static func text(display: FolderCountDisplay, unread: Int?, total: Int?) -> String? {
        switch display {
        case .unread:
            guard let unread, unread > 0 else { return nil }
            return "\(unread)"
        case .total:
            guard let total, total > 0 else { return nil }
            return "\(total)"
        case .both:
            // For folders whose counts haven't been fetched yet the badge is
            // suppressed entirely rather than rendered as `0/0`, which looks
            // like a real (and confusing) zero-mailbox.
            guard let total else { return nil }
            return "\(unread ?? 0)/\(total)"
        }
    }

    /// The badge's spoken form, for the same three modes. `nil` whenever
    /// `text` is — a hidden badge says nothing.
    static func accessibilityLabel(display: FolderCountDisplay, unread: Int?, total: Int?) -> String? {
        guard text(display: display, unread: unread, total: total) != nil else { return nil }
        switch display {
        case .unread: return "\(unread ?? 0) unread"
        case .total: return "\(total ?? 0) items"
        case .both: return "\(unread ?? 0) unread of \(total ?? 0)"
        }
    }
}

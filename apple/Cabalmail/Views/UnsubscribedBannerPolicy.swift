import Foundation
import CabalmailKit

/// Whether the message list should show its "this folder is unsubscribed"
/// banner for the folder it is displaying.
///
/// The rule reads the subscription from the LSUB set the sidebar publishes
/// (`AppState.subscribedFolderPaths`), keyed by path, and only falls back
/// to the `Folder` value's own flag while no list has landed yet. The
/// `Folder` the list is handed is not always the fetched one: the
/// resume-position toast, a push-notification tap, Spotlight, and Siri all
/// select a stand-in `Folder(path:)` whose `isSubscribed` is the
/// initializer's default (`false`), and only INBOX ever got reconciled
/// against the fetched list. Gating on that flag put the banner under
/// subscribed folders whenever the user arrived by one of those routes,
/// and it also could not follow a subscribe / unsubscribe of the folder
/// on screen, since the selection keeps the pre-toggle value.
enum UnsubscribedBannerPolicy {
    /// `true` when the banner belongs under `folder`.
    ///
    /// - `subscribedPaths` known: the banner shows exactly when the path is
    ///   absent from it, whatever the `Folder` value claims.
    /// - `subscribedPaths` unknown (no folder list yet): trust the value's
    ///   flag. That is right for the launch landing, which seeds INBOX as
    ///   subscribed, and wrong for a stand-in only for the moment before
    ///   the concurrent folder-list load publishes the real answer.
    static func shouldShow(folder: Folder, subscribedPaths: Set<String>?) -> Bool {
        guard let subscribedPaths else { return !folder.isSubscribed }
        return !subscribedPaths.contains(folder.path)
    }

    /// Lines the banner's sentence may wrap to.
    ///
    /// The banner lives in a `safeAreaInset`, so its *ideal* height is part of
    /// the hosting window's minimum content height — and an unbounded
    /// `.fixedSize(horizontal: false, vertical: true)` label has no ideal
    /// height until it is given a width. AppKit computes a window minimum by
    /// proposing a width near zero, where the sentence wraps to roughly one
    /// word per line: measured 731 pt, which is where #1355's 973 pt minimum
    /// window height came from. Three lines caps that at 54 pt.
    ///
    /// Three, not two, because the narrowest width the banner is ever laid out
    /// at for real is `ListColumnWidth.squeezedMinimum` (220 pt, the macOS
    /// message-list column in a window too narrow to seat all three at their
    /// preferred widths; iPad and visionOS floor the column at
    /// `ListColumnWidth.minimum`, and compact iPhone gives it the screen).
    /// The sentence needs three lines there — measured 55 pt unbounded, 55 pt
    /// at this limit, 41 pt at two — so this is the tightest bound that never
    /// truncates on any surface that can draw it.
    static let messageLineLimit = 3
}

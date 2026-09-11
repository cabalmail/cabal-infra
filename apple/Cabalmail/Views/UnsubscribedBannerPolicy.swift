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
}

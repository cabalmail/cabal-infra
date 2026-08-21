import Foundation
import CabalmailKit

/// The bulk action bar's first button — its caption, its glyph, and the
/// operation behind it — resolved from the folder on screen alone.
///
/// A pure rule rather than an inline `if` in `MessageListView+Bulk`, for the
/// same reason `CompactColumnPolicy` is one: the bar is drawn inside a
/// `safeAreaInset` on a view whose state a unit test can't reach, and this
/// is.
///
/// The button is an *explicitly* Archive affordance — the surface
/// `DisposeIntent.archiving(in:)` already names in its own documentation —
/// so it takes no `DisposeAction` preference. That omission is the point:
/// the button used to draw "Archive" while dispatching the preference, so a
/// user running `Dispose action = Trash` deleted every selection they asked
/// to archive (#1164). Caption, glyph and intent now come out of one call,
/// which is what keeps them from disagreeing again.
enum BulkArchiveButtonPolicy {
    /// What the button says and does. `intent` is never `.purge`: the bar
    /// draws a separate, destructive Delete for that, inside Trash only.
    struct Button: Equatable {
        let title: String
        let systemImage: String
        let intent: DisposeIntent
    }

    static func button(in folderPath: String) -> Button {
        let intent = DisposeIntent.archiving(in: folderPath)
        switch intent {
        case .restore:
            // Inside Archive an archive would be a same-folder move, so the
            // button puts the selection back in the inbox instead.
            return Button(title: "Restore", systemImage: "tray.and.arrow.up", intent: intent)
        default:
            // Everywhere else — including Trash, where this is the rescue
            // path out of the deleted pile — it files into Archive.
            return Button(title: "Archive", systemImage: "archivebox", intent: intent)
        }
    }
}

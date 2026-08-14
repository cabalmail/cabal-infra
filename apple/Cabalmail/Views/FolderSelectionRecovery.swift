import Foundation
import CabalmailKit

/// Where the sidebar's selection should land once the folder list changes
/// under it.
///
/// `FolderListView` owns a `Binding<Folder?>` the parent split view reads to
/// decide what the message-list column shows. Deleting a folder prunes the
/// row but says nothing about that binding, so a selection pointing at the
/// deleted folder survives its target: the column keeps requesting a path the
/// server no longer has and the API answers 500 (#1062).
///
/// The rule is deliberately written against the *surviving* list rather than
/// against the deleted path. Deleting a folder that has children leaves those
/// children in place (IMAP keeps the name as a `\Noselect` container), so a
/// selection is only stale if it isn't in the list any more — which is also
/// what makes deleting a folder other than the selected one a no-op here.
enum FolderSelectionRecovery {
    /// The selection to hold given the folders that still exist. Returns
    /// `current` untouched when it survives, INBOX when it doesn't, and the
    /// first surviving folder if even INBOX is missing.
    static func selection(current: Folder?, remaining: [Folder]) -> Folder? {
        guard let current else { return nil }
        if remaining.contains(where: { $0.path == current.path }) {
            return current
        }
        return remaining.first { $0.path == FolderTree.inboxPath } ?? remaining.first
    }
}

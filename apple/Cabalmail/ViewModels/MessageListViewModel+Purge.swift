import Foundation
import CabalmailKit

// Permanent deletion out of Trash. Lives in a sibling extension so the
// main view-model file stays under SwiftLint's caps. Mirrors
// `dispose(_:)`'s optimistic-prune-then-revert shape, but the wire call
// is `purge` (flag `\Deleted` + expunge server-side) — the message does
// not land anywhere else, so views must confirm with the user before
// calling this.
extension MessageListViewModel {
    /// True when this list shows the Trash folder. Delete affordances
    /// (swipe, context menu, selection menu, action bar, Cmd+Delete)
    /// switch from "move to Trash" to "delete forever" and route
    /// through a confirmation dialog.
    var isTrashFolder: Bool { folder.path == FolderTree.trashPath }

    /// Permanently delete an explicit UID set. Serves both the single-
    /// row surfaces (swipe, row menu — a one-element set) and the
    /// multi-selection surfaces (selection menu, action bar,
    /// Cmd+Delete); every caller confirms with the user first.
    ///
    /// Mirrors `performMove`'s optimistic prune / restore shape. UIDs
    /// whose row isn't truly in Trash (a cross-folder search row, or a
    /// UID already mid-removal) are dropped up front — the
    /// `/purge_messages` Lambda rejects non-trash folders, so gating
    /// client-side turns a mis-wired call into a no-op rather than a
    /// server error toast.
    func purgeMessages(uids: Set<UInt32>) async {
        let condemned = envelopes.filter {
            uids.contains($0.uid) && sourceFolder(for: $0) == FolderTree.trashPath
        }
        guard !condemned.isEmpty else { return }
        let condemnedUIDs = Set(condemned.map(\.uid))
        let unreadCount = condemned.filter { !$0.flags.contains(.seen) }.count

        envelopes.removeAll { condemnedUIDs.contains($0.uid) }
        pendingRemovedUIDs.formUnion(condemnedUIDs)
        defer { pendingRemovedUIDs.subtract(condemnedUIDs) }
        if unreadCount > 0 {
            appState.applyUnreadDelta(folderPath: FolderTree.trashPath, delta: -unreadCount)
        }

        do {
            try await client.imapClient.purge(
                folder: FolderTree.trashPath,
                uids: condemned.map(\.uid)
            )
            await pruneCachesAfter(move: FolderTree.trashPath, uids: condemned.map(\.uid))
        } catch {
            envelopes.append(contentsOf: condemned)
            envelopes.sort(by: envelopeOrder)
            if unreadCount > 0 {
                appState.applyUnreadDelta(folderPath: FolderTree.trashPath, delta: unreadCount)
            }
            errorMessage = "\(error)"
        }
        // Purged rows leave any active selection; like `moveMessages`,
        // UIDs outside the set stay selected.
        selectedUIDs.subtract(condemnedUIDs)
    }
}

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

    /// What the preference-driven dispose affordances (trailing swipe,
    /// Cmd+Delete) mean in this folder, and what an explicitly-Archive
    /// affordance (context menus, bulk action bar) means. Both resolve
    /// through `DisposeIntent` so the folder-specific cases — Delete
    /// Forever in Trash, Restore in Archive — can't drift between the
    /// label a surface draws and the operation it runs.
    var disposeIntent: DisposeIntent {
        .standard(preference: disposeAction, in: folder.path)
    }

    var archiveIntent: DisposeIntent {
        .archiving(in: folder.path)
    }

    /// Permanently delete an explicit ref set. Serves both the single-
    /// row surfaces (swipe, row menu — a one-element set) and the
    /// multi-selection surfaces (selection menu, action bar,
    /// Cmd+Delete); every caller confirms with the user first.
    ///
    /// Mirrors `performMove`'s optimistic prune / restore shape. Refs
    /// whose row isn't truly in Trash (a cross-folder search row, or a
    /// message already mid-removal) are dropped up front — the
    /// `/purge_messages` Lambda rejects non-trash folders, so gating
    /// client-side turns a mis-wired call into a no-op rather than a
    /// server error toast.
    ///
    /// The rows are replaced before anything leaves: a full swipe's Delete
    /// Forever held its row slid open while the dialog asked (see
    /// `replaceRows(showing:)`), and the message moving up into that row
    /// would otherwise inherit it -- as would the message itself if the
    /// purge is refused.
    func purgeMessages(refs: Set<MessageRef>) async {
        replaceRows(showing: refs)
        let condemned = loadedRows(refs).filter { rowRef(for: $0).folder == FolderTree.trashPath }
        guard !condemned.isEmpty else { return }
        let condemnedRefs = Set(condemned.map { rowRef(for: $0) })
        let unreadCount = condemned.filter { !$0.flags.contains(.seen) }.count

        envelopes.removeAll { condemnedRefs.contains(rowRef(for: $0)) }
        adjustTotalMessages(by: -condemned.count)
        mailStore.shields.beginRemoval(condemnedRefs)
        defer { mailStore.shields.endRemoval(condemnedRefs) }
        if unreadCount > 0 {
            mailStore.counts.applyUnreadDelta(folderPath: FolderTree.trashPath, delta: -unreadCount)
        }

        do {
            try await client.imapClient.purge(
                folder: FolderTree.trashPath,
                uids: condemned.map(\.uid)
            )
            await confirmRemoval(from: FolderTree.trashPath, uids: condemned.map(\.uid))
        } catch {
            // A search re-run while the purge was out may already have put
            // the rows back; each message is listed once.
            let restored = condemned.filter { index(of: rowRef(for: $0)) == nil }
            envelopes.append(contentsOf: restored)
            envelopes.sort(by: envelopeOrder)
            adjustTotalMessages(by: restored.count)
            // Not once the session has ended (#1851).
            if unreadCount > 0, mailStore.acceptsCounts(from: client) {
                mailStore.counts.applyUnreadDelta(folderPath: FolderTree.trashPath, delta: unreadCount)
            }
            errorMessage = error.localizedDescription
        }
        // Purged rows leave any active selection; like `moveMessages`,
        // messages outside the set stay selected.
        selectedRefs.subtract(condemnedRefs)
    }
}

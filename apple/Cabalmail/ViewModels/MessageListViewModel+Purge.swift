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
    /// (swipe, context menu) switch from "move to Trash" to "delete
    /// forever" and route through a confirmation dialog.
    var isTrashFolder: Bool { folder.path == FolderTree.trashPath }

    func purge(_ envelope: Envelope) async {
        let source = sourceFolder(for: envelope)
        // The `/purge_messages` Lambda rejects non-trash folders; gate
        // client-side too so a mis-wired call surfaces as a no-op rather
        // than a server error toast.
        guard source == FolderTree.trashPath else { return }
        guard pendingRemovedUIDs.insert(envelope.uid).inserted else { return }
        defer { pendingRemovedUIDs.remove(envelope.uid) }

        let originalIndex = envelopes.firstIndex { $0.uid == envelope.uid }
        let wasUnread = !envelope.flags.contains(.seen)
        envelopes.removeAll { $0.uid == envelope.uid }
        if wasUnread {
            appState.applyUnreadDelta(folderPath: source, delta: -1)
        }

        do {
            try await client.imapClient.purge(folder: source, uids: [envelope.uid])
            await pruneCachesAfter(move: source, uid: envelope.uid)
        } catch {
            restoreEnvelope(envelope, at: originalIndex)
            if wasUnread {
                appState.applyUnreadDelta(folderPath: source, delta: 1)
            }
            errorMessage = "\(error)"
        }
    }
}

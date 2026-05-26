import Foundation
import CabalmailKit

// Per-envelope "Move to folder…" path. Lives in a sibling extension so
// the main view-model file stays under SwiftLint's 400-line cap. The
// flow mirrors `dispose(_:)`'s optimistic-prune-then-revert shape but
// takes a destination path directly and does NOT mark `\Seen` before
// the move: archive's "I'm done with this" implies read; filing into
// a project folder doesn't, and forcing the read bit would surprise
// users who rely on unread state as a "come back to it" marker.
//
// Re-entrance: the sheet binding gates double-fire at the UI layer
// (one envelope owns one sheet at a time), so we skip the `pendingDispose
// UIDs` guard that `dispose(_:)` uses for rapid-swipe protection.
extension MessageListViewModel {
    func moveTo(_ envelope: Envelope, destination: String) async {
        let source = sourceFolder(for: envelope)
        guard source != destination else { return }
        let originalIndex = envelopes.firstIndex { $0.uid == envelope.uid }
        let wasUnread = !envelope.flags.contains(.seen)
        envelopes.removeAll { $0.uid == envelope.uid }
        if wasUnread {
            appState.applyUnreadDelta(folderPath: source, delta: -1)
            appState.applyUnreadDelta(folderPath: destination, delta: 1)
        }

        do {
            try await client.imapClient.move(
                folder: source,
                uids: [envelope.uid],
                destination: destination
            )
            await pruneCachesAfter(move: source, uid: envelope.uid)
        } catch {
            restoreEnvelope(envelope, at: originalIndex)
            if wasUnread {
                appState.applyUnreadDelta(folderPath: source, delta: 1)
                appState.applyUnreadDelta(folderPath: destination, delta: -1)
            }
            errorMessage = "\(error)"
        }
    }
}

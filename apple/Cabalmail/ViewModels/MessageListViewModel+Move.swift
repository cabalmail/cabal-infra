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
        // Shield the removal from a concurrent refresh: until the move lands
        // the source folder still returns this UID, and an unshielded merge
        // would resurrect the row.
        pendingRemovedUIDs.insert(envelope.uid)
        defer { pendingRemovedUIDs.remove(envelope.uid) }
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

    /// Perform a drag-and-drop move posted from a sidebar folder. The payload
    /// already carries each UID's owning mailbox, so we group by source and
    /// hand off to the shared `performMove`. UIDs that were part of an active
    /// bulk selection are dropped from `selectedUIDs` afterwards so the
    /// action bar's count stays truthful; bulk mode itself is left as the
    /// user set it (a drag isn't a "done selecting" signal).
    func applyMoveRequest(_ request: MessageMoveRequest) async {
        let grouping = Dictionary(grouping: request.items, by: \.sourceFolder)
            .mapValues { $0.map(\.uid) }
        await performMove(uidsBySource: grouping, to: request.destination, markSeenFirst: false)
        selectedUIDs.subtract(request.items.map(\.uid))
    }

    /// Shared optimistic move used by the bulk-action bar and the drag-and-
    /// drop path. `uidsBySource` groups the UIDs to move by their owning
    /// mailbox (single-folder lists collapse to one bucket; cross-folder
    /// search selections may span several). Groups whose source already
    /// equals the destination are skipped entirely - moving a message onto
    /// its own folder is a no-op, and pruning it optimistically would make
    /// the row vanish until the next refetch.
    ///
    /// `markSeenFirst` mirrors the dispose path: bulk-archive marks each
    /// message `\Seen` before the move (archived == read) so the source
    /// loses the unread but the destination doesn't gain it; a plain move
    /// carries unread state with the message.
    func performMove(
        uidsBySource: [String: [UInt32]],
        to destination: String,
        markSeenFirst: Bool
    ) async {
        let groups = uidsBySource.filter { $0.key != destination && !$0.value.isEmpty }
        guard !groups.isEmpty else { return }
        let movingUIDs = Set(groups.values.flatMap { $0 })
        let snapshot = envelopes.filter { movingUIDs.contains($0.uid) }
        let unreadBySource = Dictionary(
            grouping: snapshot.filter { !$0.flags.contains(.seen) },
            by: { sourceFolder(for: $0) }
        ).mapValues { $0.count }

        // Optimistic prune. A per-source failure reinserts that group below.
        // Shield every moving UID from a concurrent refresh until the whole
        // batch settles - the source folders keep returning them until their
        // move lands, and an unshielded merge would resurrect the rows.
        envelopes.removeAll { movingUIDs.contains($0.uid) }
        pendingRemovedUIDs.formUnion(movingUIDs)
        defer { pendingRemovedUIDs.subtract(movingUIDs) }
        for (source, count) in unreadBySource {
            appState.applyUnreadDelta(folderPath: source, delta: -count)
            if !markSeenFirst {
                appState.applyUnreadDelta(folderPath: destination, delta: count)
            }
        }

        for (source, uids) in groups {
            do {
                // Bulk archive folds the mark-seen into the move (server adds
                // `\Seen` before relocating), so a large dispose is one round
                // trip per source instead of a STORE plus a MOVE — the same
                // background-window economy as the single-row swipe path.
                try await client.imapClient.move(
                    folder: source, uids: uids,
                    destination: destination, markSeen: markSeenFirst
                )
                await pruneCachesAfter(move: source, uids: uids)
            } catch CabalmailError.bulkPartialFailure(let succeeded, let failed) {
                restoreAfterPartialMove(
                    source: source, destination: destination, snapshot: snapshot,
                    failed: failed, markSeenFirst: markSeenFirst
                )
                await pruneCachesAfter(move: source, uids: Array(succeeded))
                errorMessage = "Moved \(succeeded.count) of \(uids.count) messages. "
                    + "\(failed.count) could not be moved."
            } catch {
                restoreAfterFailedMove(
                    source: source, destination: destination, snapshot: snapshot,
                    unread: unreadBySource[source] ?? 0, markSeenFirst: markSeenFirst
                )
                errorMessage = "\(error)"
            }
        }
    }

    /// Whole-group revert for a move that failed outright: every row from
    /// `source` comes back and its unread count returns to the source (and
    /// leaves the destination, when the optimistic pass had granted it).
    private func restoreAfterFailedMove(
        source: String,
        destination: String,
        snapshot: [Envelope],
        unread: Int,
        markSeenFirst: Bool
    ) {
        let restored = snapshot.filter { sourceFolder(for: $0) == source }
        envelopes.append(contentsOf: restored)
        envelopes.sort(by: envelopeOrder)
        appState.applyUnreadDelta(folderPath: source, delta: unread)
        if !markSeenFirst {
            appState.applyUnreadDelta(folderPath: destination, delta: -unread)
        }
    }

    /// Partial-failure counterpart of `performMove`'s whole-group revert:
    /// only the failed rows come back. On a dispose (`markSeenFirst`) the
    /// restored rows re-appear as read — the seen-marking already landed
    /// server-side and the top-of-move unread subtraction assumed it — so
    /// no unread deltas move; a plain move hands the failed rows' unread
    /// counts back to the source and reclaims them from the destination.
    private func restoreAfterPartialMove(
        source: String,
        destination: String,
        snapshot: [Envelope],
        failed: Set<UInt32>,
        markSeenFirst: Bool
    ) {
        let restored = snapshot.filter {
            sourceFolder(for: $0) == source && failed.contains($0.uid)
        }
        envelopes.append(contentsOf: restored)
        envelopes.sort(by: envelopeOrder)
        if markSeenFirst {
            for envelope in restored {
                applyOptimisticFlag(uid: envelope.uid, flag: .seen, add: true)
            }
        } else {
            let unread = restored.filter { !$0.flags.contains(.seen) }.count
            appState.applyUnreadDelta(folderPath: source, delta: unread)
            appState.applyUnreadDelta(folderPath: destination, delta: -unread)
        }
    }
}

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
// (one envelope owns one sheet at a time), so we skip the
// `MessageShields.isRemoving` guard that `dispose(_:)` uses for
// rapid-swipe protection. The writes themselves go through the mail
// store's mutation service (`MailMutationService`).
extension MessageListViewModel {
    func moveTo(_ envelope: Envelope, destination: String) async {
        let ref = rowRef(for: envelope)
        guard ref.folder != destination else { return }
        let originalIndex = index(of: ref)
        let wasUnread = !envelope.flags.contains(.seen)
        let loadedBefore = envelopes.count
        if let originalIndex { envelopes.remove(at: originalIndex) }
        // Drop the vacated slot from the folder total too, or the index-
        // addressed list keeps rendering an unresolvable skeleton row in it
        // (and the All pill keeps counting it) until the next STATUS.
        adjustTotalMessages(by: envelopes.count - loadedBefore)
        // The service shields the removal from a concurrent refresh (until
        // the move lands the source folder still returns this UID, and an
        // unshielded merge would resurrect the row), drops the row from every
        // other list, and moves an unread message's count with it. This list
        // holds the removal a moment longer, until it has put a refused row
        // back itself, so a merge in between can't put it back first.
        mailStore.shields.beginRemoval([ref])
        defer { mailStore.shields.endRemoval([ref]) }
        let outcome = await mailStore.mutations.remove(
            [ref], .move(to: destination, markingSeen: false),
            unread: wasUnread ? [ref] : [], by: .list(self, through: client)
        ).value
        if outcome.confirmed.contains(ref) { removalsConfirmed() }
        guard outcome.failed.contains(ref) else { return }
        restoreEnvelope(envelope, at: originalIndex)
        errorMessage = outcome.message
    }

    /// What dragging `envelope`'s row carries. When a multi-selection exists
    /// and this row is part of it, the whole selection, in list order;
    /// otherwise just this row - matching Finder / Mail, where grabbing an
    /// unselected item drags only it. Each item is a row's own ref, so a
    /// cross-folder search selection routes every message back to its own
    /// folder on drop, and dragging one of two rows that share a UID lifts
    /// only that one.
    func dragItems(liftedFrom envelope: Envelope) -> [MessageDragItem] {
        if selectedRefs.count > 1, isSelected(envelope) {
            return loadedRows(selectedRefs).map { MessageDragItem(rowRef(for: $0)) }
        }
        return [MessageDragItem(rowRef(for: envelope))]
    }

    /// Perform a drag-and-drop move posted from a sidebar folder. The payload
    /// carries each message's ref (its owning mailbox and UID), so we group
    /// by source and hand off to the shared `performMove`. Dragged messages
    /// that were part of an active bulk selection are dropped from
    /// `selectedRefs` afterwards so the action bar's count stays truthful;
    /// bulk mode itself is left as the user set it (a drag isn't a "done
    /// selecting" signal).
    func applyMoveRequest(_ request: MessageMoveRequest) async {
        let refs = request.items.map(\.ref)
        await performMove(uidsBySource: refs.uidsByFolder(), to: request.destination, markSeenFirst: false)
        selectedRefs.subtract(refs)
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
    /// carries unread state with the message. Bulk archive folds the
    /// mark-seen into the move (the server adds `\Seen` before relocating),
    /// so a large dispose is one round trip per source instead of a STORE
    /// plus a MOVE -- the same background-window economy as the single-row
    /// swipe path.
    ///
    /// The rows leave this list at once; the mutation service shields the
    /// whole batch from a concurrent refresh until it settles, drops the
    /// rows from every other list, and moves the unread counts. A source
    /// whose move fails outright puts all its rows back; one the server
    /// moved in part puts back only the refused rows, read on a dispose
    /// (the seen-marking landed server-side before the move failed), with
    /// an "X of Y" message.
    ///
    /// The groups are already folder-qualified, so the prune, the shield and
    /// every revert work on the moving messages' refs: a row elsewhere in a
    /// cross-folder search that shares a UID with a moving one is not moved,
    /// pruned or counted.
    func performMove(
        uidsBySource: [String: [UInt32]],
        to destination: String,
        markSeenFirst: Bool
    ) async {
        let groups = uidsBySource.filter { $0.key != destination && !$0.value.isEmpty }
        guard !groups.isEmpty else { return }
        // Each message once: a row loaded twice is still one message.
        var listed = Set<MessageRef>()
        let moving = groups.flatMap { folder, uids in uids.map { MessageRef(folder: folder, uid: $0) } }
            .filter { listed.insert($0).inserted }
        let movingRefs = Set(moving)
        let snapshot = envelopes.filter { movingRefs.contains(rowRef(for: $0)) }
        let unread = Set(snapshot.filter { !$0.flags.contains(.seen) }.map { rowRef(for: $0) })

        let loadedBefore = envelopes.count
        envelopes.removeAll { movingRefs.contains(rowRef(for: $0)) }
        adjustTotalMessages(by: envelopes.count - loadedBefore)
        // Held until the refused rows are back, as in `moveTo`.
        mailStore.shields.beginRemoval(moving)
        defer { mailStore.shields.endRemoval(moving) }
        let outcome = await mailStore.mutations.remove(
            moving, .move(to: destination, markingSeen: markSeenFirst),
            unread: unread, by: .list(self, through: client)
        ).value
        if !outcome.confirmed.isEmpty { removalsConfirmed() }
        guard !outcome.failed.isEmpty else { return }
        let restored = snapshot.filter {
            outcome.failed.contains(rowRef(for: $0)) && index(of: rowRef(for: $0)) == nil
        }
        envelopes.append(contentsOf: restored)
        envelopes.sort(by: envelopeOrder)
        adjustTotalMessages(by: restored.count)
        for envelope in restored where outcome.markedRead.contains(rowRef(for: envelope)) {
            applyOptimisticFlag(rowRef(for: envelope), flag: .seen, add: true)
        }
        errorMessage = outcome.message
    }
}

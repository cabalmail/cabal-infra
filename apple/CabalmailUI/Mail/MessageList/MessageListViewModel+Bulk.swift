import Foundation
import CabalmailKit

// Multi-select / ref-set action plumbing. Lives in a sibling extension
// so the main view-model file stays under SwiftLint's 400-line cap.
// The ref-set primitives (`setSeen(_:refs:)`, `setFlagged(_:refs:)`,
// `moveMessages(refs:to:)`, `disposeMessages(refs:action:)`) serve the
// bulk-action bar, the selection context menu, and the keyboard
// shortcuts; each is a thin wrapper over the existing UID-array wire
// calls (`setFlags(uids:)`, `move(uids:)`) plus optimistic in-memory
// updates that mirror the per-row flows. Every ref names its own folder,
// so a cross-folder search selection is grouped by mailbox before the
// wire call and each server-side move/store reaches exactly the messages
// picked — two rows that share a UID are two different refs.
//
// Selection lifetime: flag toggles (seen / flagged) leave the selection
// alone so the user can chain operations on the same messages; moves
// and disposes drop exactly the moved refs, since those rows are gone.
extension MessageListViewModel {
    /// Toggle edit mode. Leaving edit mode also clears any selection so
    /// re-entering starts fresh.
    func toggleBulkMode() {
        bulkMode.toggle()
        if !bulkMode { selectedRefs.removeAll() }
    }

    func exitBulkMode() {
        bulkMode = false
        selectedRefs.removeAll()
    }

    /// Leave selection mode without touching the selection. The bulk move /
    /// dispose paths hand their refs to an async `Task` and clear the set
    /// themselves once it has read them, so the view dropping the mode
    /// straight after must not clear it here — that would race the read and
    /// move nothing.
    func leaveBulkMode() {
        bulkMode = false
    }

    /// Flip an envelope's row in or out of the selection set.
    /// Whether `envelope`'s row is selected: what the row's highlight and
    /// checkbox draw. Of two rows sharing a UID, only the one picked is.
    func isSelected(_ envelope: Envelope) -> Bool {
        selectedRefs.contains(rowRef(for: envelope))
    }

    func toggleSelection(_ envelope: Envelope) {
        let ref = rowRef(for: envelope)
        if selectedRefs.contains(ref) {
            selectedRefs.remove(ref)
        } else {
            selectedRefs.insert(ref)
        }
    }

    /// Select every envelope currently passing the active filter tab
    /// (the visible list). "Select all" without filtering would surprise
    /// — the user sees only the unread tab, expects to flag those, not
    /// every read message too.
    func selectAllVisible() {
        let visible = envelopes.filter { filterTab.includes($0) }
        selectedRefs = Set(visible.map { rowRef(for: $0) })
    }

    /// The loaded rows `refs` names, in list order. Every bulk path acts on
    /// these rather than on the refs themselves, so a selected message that
    /// has since left the window (or the results) is left alone, as it
    /// always was.
    func loadedRows(_ refs: Set<MessageRef>) -> [Envelope] {
        envelopes.filter { refs.contains(rowRef(for: $0)) }
    }

    /// Group a ref set's loaded rows by their folder, in list order, as the
    /// wire calls take them. Single-folder lists collapse to one bucket;
    /// cross-folder search results may produce several.
    private func groupedByFolder(_ refs: Set<MessageRef>) -> [String: [UInt32]] {
        loadedRows(refs).map { rowRef(for: $0) }.uidsByFolder()
    }

    /// Bulk equivalent of `dispose(_:)`, scoped to the selection and to
    /// the configured dispose destination. Exits edit mode — the rows
    /// are gone, so the action bar has nothing left to act on.
    func bulkDispose() async {
        await disposeMessages(refs: selectedRefs, action: preferences.disposeAction)
        exitBulkMode()
    }

    /// Bulk equivalent of `moveTo(_:destination:)`, scoped to the
    /// selection. Exits edit mode like `bulkDispose()`.
    func bulkMove(to destination: String) async {
        await moveMessages(refs: selectedRefs, to: destination)
        exitBulkMode()
    }

    /// Selection-scoped wrappers for the action bar. Unlike the move /
    /// dispose paths these deliberately do NOT exit edit mode: the rows
    /// are still on screen, and keeping the selection lets the user
    /// chain another action (flag, move) onto the same messages.
    func bulkSetSeen(_ shouldBeSeen: Bool) async {
        await setSeen(shouldBeSeen, refs: selectedRefs)
    }

    func bulkSetFlagged(_ shouldBeFlagged: Bool) async {
        await setFlagged(shouldBeFlagged, refs: selectedRefs)
    }

    /// \Seen / unset-\Seen for an explicit ref set. Walks the set per-
    /// source-folder. Optimistically updates the in-memory flags so the
    /// row styling flips before the wire call lands; rows the server
    /// rejects (whole-group or `bulkPartialFailure` split) revert to
    /// their pre-op state. Leaves any active selection intact.
    func setSeen(_ shouldBeSeen: Bool, refs: Set<MessageRef>) async {
        let rows = loadedRows(refs)
        let grouping = groupedByFolder(refs)
        let loaded = Set(rows.map { rowRef(for: $0) })
        let prior = priorFlagState(rows, flag: .seen)
        // Unread badge tracking — capture the actual transition UIDs per
        // folder BEFORE the optimistic loop rewrites the flags: marking an
        // already-read message read must not move the sidebar counter, and
        // a partial failure must only count transitions that landed.
        let transitionsByFolder = Dictionary(
            grouping: rows.filter { $0.flags.contains(.seen) != shouldBeSeen }.map { rowRef(for: $0) },
            by: \.folder
        ).mapValues { Set($0.map(\.uid)) }
        for ref in loaded {
            applyOptimisticFlag(ref, flag: .seen, add: shouldBeSeen)
        }
        pendingFlagRefs.formUnion(loaded)
        defer { pendingFlagRefs.subtract(loaded) }
        for (source, groupUIDs) in grouping {
            let applied = await applyFlagGroup(
                folder: source, uids: groupUIDs,
                flag: .seen, add: shouldBeSeen, prior: prior
            )
            let transitions = transitionsByFolder[source]?.intersection(applied).count ?? 0
            // The STORE answered: not once the session has ended (#1851).
            if transitions > 0, mailStore.acceptsCounts(from: client) {
                mailStore.counts.applyUnreadDelta(
                    folderPath: source,
                    delta: shouldBeSeen ? -transitions : transitions
                )
            }
        }
    }

    /// Flag toggle for an explicit ref set. Mirrors `setSeen` minus the
    /// unread-count bookkeeping (flagged isn't a count we surface in
    /// the sidebar).
    func setFlagged(_ shouldBeFlagged: Bool, refs: Set<MessageRef>) async {
        let rows = loadedRows(refs)
        let grouping = groupedByFolder(refs)
        let loaded = Set(rows.map { rowRef(for: $0) })
        let prior = priorFlagState(rows, flag: .flagged)
        for ref in loaded {
            applyOptimisticFlag(ref, flag: .flagged, add: shouldBeFlagged)
        }
        pendingFlagRefs.formUnion(loaded)
        defer { pendingFlagRefs.subtract(loaded) }
        for (source, groupUIDs) in grouping {
            _ = await applyFlagGroup(
                folder: source, uids: groupUIDs,
                flag: .flagged, add: shouldBeFlagged, prior: prior
            )
        }
    }

    /// Pre-op flag membership per row, captured before the optimistic
    /// rewrite so a rejected row can revert to exactly what it had — a
    /// blind "apply the opposite" would corrupt rows that already carried
    /// the target state (e.g. mark-read over an already-read message).
    private func priorFlagState(_ rows: [Envelope], flag: Flag) -> [MessageRef: Bool] {
        // Uniquing rather than `uniqueKeysWithValues:`, which traps on a
        // repeated key: a row loaded twice is still one message.
        Dictionary(
            rows.map { (rowRef(for: $0), $0.flags.contains(flag)) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    /// One flag-group wire call plus reconciliation: returns the UIDs the
    /// server actually applied. A `bulkPartialFailure` keeps the succeeded
    /// rows, reverts the failed ones, and surfaces an "X of Y" message;
    /// any other error reverts the whole group. The server's UIDs are the
    /// group's, so each is reverted as a message in `folder`.
    private func applyFlagGroup(
        folder: String,
        uids: [UInt32],
        flag: Flag,
        add: Bool,
        prior: [MessageRef: Bool]
    ) async -> Set<UInt32> {
        func revert(_ uids: some Sequence<UInt32>) {
            for uid in uids {
                let ref = MessageRef(folder: folder, uid: uid)
                applyOptimisticFlag(ref, flag: flag, add: prior[ref] ?? !add)
            }
        }
        do {
            try await client.imapClient.setFlags(
                folder: folder, uids: uids, flags: [flag],
                operation: add ? .add : .remove
            )
            return Set(uids)
        } catch CabalmailError.bulkPartialFailure(let succeeded, let failed) {
            revert(failed)
            errorMessage = "Updated \(succeeded.count) of \(uids.count) messages. "
                + "\(failed.count) could not be updated."
            return succeeded
        } catch {
            revert(uids)
            errorMessage = error.localizedDescription
            return []
        }
    }

    /// Move an explicit ref set. The optimistic prune / unread
    /// bookkeeping / per-source revert all live in the shared
    /// `performMove` (also used by drag-and-drop). Moved refs drop out
    /// of any active selection; refs outside the set stay selected, so
    /// a context-menu move on an unselected row leaves the user's
    /// selection alone.
    func moveMessages(refs: Set<MessageRef>, to destination: String) async {
        await performMove(uidsBySource: groupedByFolder(refs), to: destination, markSeenFirst: false)
        selectedRefs.subtract(refs)
    }

    /// Archive or trash an explicit ref set. `action` is a parameter
    /// rather than the dispose preference so the context menu can offer
    /// both destinations side by side; marks `\Seen` first to match the
    /// single-row dispose (archived == read).
    func disposeMessages(refs: Set<MessageRef>, action: DisposeAction) async {
        await performMove(
            uidsBySource: groupedByFolder(refs),
            to: action.destinationFolder,
            markSeenFirst: true
        )
        selectedRefs.subtract(refs)
    }
}

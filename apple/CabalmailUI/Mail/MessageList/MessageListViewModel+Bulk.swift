import Foundation
import CabalmailKit

// Multi-select / ref-set action plumbing. Lives in a sibling extension
// so the main view-model file stays under SwiftLint's 400-line cap.
// The ref-set primitives (`setSeen(_:refs:)`, `setFlagged(_:refs:)`,
// `moveMessages(refs:to:)`, `disposeMessages(refs:action:)`) serve the
// bulk-action bar, the selection context menu, and the keyboard
// shortcuts; each makes its optimistic in-memory updates, mirroring the
// per-row flows, and hands the write to the mail store's mutation service
// (`MailMutationService`). Every ref names its own folder, so the service
// groups a cross-folder search selection by mailbox for the wire calls and
// each server-side move/store reaches exactly the messages picked — two
// rows that share a UID are two different refs.
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

    /// \Seen / unset-\Seen for an explicit ref set. Optimistically updates
    /// the in-memory flags so the row styling flips before the wire call
    /// lands, and sends one write through the mutation service, which
    /// moves each folder's unread count at once for the rows that actually
    /// flip (marking an already-read message read moves nothing) and puts
    /// it back for any the server refuses. Rows the server rejects (a whole
    /// folder's group, or the failed part of a `bulkPartialFailure`) revert
    /// to their pre-op state. Leaves any active selection intact.
    func setSeen(_ shouldBeSeen: Bool, refs: Set<MessageRef>) async {
        await setFlag(.seen, to: shouldBeSeen, refs: refs)
    }

    /// Flag toggle for an explicit ref set. The same as `setSeen`, minus the
    /// unread count.
    func setFlagged(_ shouldBeFlagged: Bool, refs: Set<MessageRef>) async {
        await setFlag(.flagged, to: shouldBeFlagged, refs: refs)
    }

    private func setFlag(_ flag: Flag, to target: Bool, refs: Set<MessageRef>) async {
        let rows = loadedRows(refs)
        let prior = priorFlagState(rows, flag: flag)
        // The loaded rows' refs in list order, each once: the order the
        // server calls take them in.
        var listed = Set<MessageRef>()
        let ordered = rows.map { rowRef(for: $0) }.filter { listed.insert($0).inserted }
        let changing = Set(ordered.filter { prior[$0] != target })
        for ref in ordered {
            applyOptimisticFlag(ref, flag: flag, add: target)
        }
        // Held until the rows the server refused are back, as in `setFlag`.
        mailStore.shields.beginFlagWrite(ordered, flag: flag, added: target)
        defer { mailStore.shields.endFlagWrite(ordered, flag: flag, added: target) }
        let outcome = await mailStore.mutations.setFlag(
            flag, added: target, on: ordered, changing: changing, by: .list(self, through: client)
        ).value
        for ref in ordered where outcome.failed.contains(ref) {
            applyOptimisticFlag(ref, flag: flag, add: prior[ref] ?? !target)
        }
        if let message = outcome.message {
            errorMessage = message
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

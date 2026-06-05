import Foundation
import CabalmailKit

// Multi-select / bulk-action plumbing. Lives in a sibling extension so
// the main view-model file stays under SwiftLint's 400-line cap. Every
// bulk operation is a thin wrapper over the existing UID-array
// primitives (`setFlags(uids:)`, `move(uids:)`) plus optimistic in-
// memory updates that mirror the per-row flows. Cross-folder search
// results are grouped by source mailbox before the wire call so the
// server-side move/store routes the UIDs correctly.
extension MessageListViewModel {
    /// Toggle edit mode. Leaving edit mode also clears any selection so
    /// re-entering starts fresh.
    func toggleBulkMode() {
        bulkMode.toggle()
        if !bulkMode { selectedUIDs.removeAll() }
    }

    func exitBulkMode() {
        bulkMode = false
        selectedUIDs.removeAll()
    }

    /// Flip an envelope's membership in the selection set.
    func toggleSelection(_ envelope: Envelope) {
        if selectedUIDs.contains(envelope.uid) {
            selectedUIDs.remove(envelope.uid)
        } else {
            selectedUIDs.insert(envelope.uid)
        }
    }

    /// Select every envelope currently passing the active filter tab
    /// (the visible list). "Select all" without filtering would surprise
    /// — the user sees only the unread tab, expects to flag those, not
    /// every read message too.
    func selectAllVisible() {
        let visible = envelopes.filter { filterTab.includes($0) }
        selectedUIDs = Set(visible.map(\.uid))
    }

    /// Group the selection by source folder. Single-folder mode and
    /// folder-scoped searches collapse to one bucket; cross-folder
    /// search results may produce several.
    private var selectedByFolder: [String: [UInt32]] {
        let chosen = envelopes.filter { selectedUIDs.contains($0.uid) }
        return Dictionary(grouping: chosen, by: { sourceFolder(for: $0) })
            .mapValues { $0.map(\.uid) }
    }

    /// Bulk equivalent of `dispose(_:)`. Marks each selected envelope
    /// `\Seen` (matching the single-row behavior — archive implies read)
    /// then moves to the configured dispose destination.
    func bulkDispose() async {
        let destination = preferences.disposeAction.destinationFolder
        await performBulkMove(to: destination, markSeenFirst: true)
    }

    /// Bulk equivalent of `moveTo(_:destination:)`. No seen-mark — same
    /// rationale as the single-row move path.
    func bulkMove(to destination: String) async {
        await performBulkMove(to: destination, markSeenFirst: false)
    }

    /// Bulk \Seen / unset-\Seen toggle. Walks the selection per-source-
    /// folder. Optimistically updates the in-memory flags so the row
    /// styling flips before the wire call lands.
    func bulkSetSeen(_ shouldBeSeen: Bool) async {
        let grouping = selectedByFolder
        for uid in selectedUIDs {
            applyOptimisticFlag(uid: uid, flag: .seen, add: shouldBeSeen)
        }
        for (source, uids) in grouping {
            try? await client.imapClient.setFlags(
                folder: source,
                uids: uids,
                flags: [.seen],
                operation: shouldBeSeen ? .add : .remove
            )
            // Unread badge tracking — only the seen toggle moves the
            // sidebar counter. Each toggled UID contributes once.
            let delta = shouldBeSeen ? -uids.count : uids.count
            appState.applyUnreadDelta(folderPath: source, delta: delta)
        }
        exitBulkMode()
    }

    /// Bulk flag toggle. Mirrors `bulkSetSeen` minus the unread-count
    /// bookkeeping (flagged isn't a count we surface in the sidebar).
    func bulkSetFlagged(_ shouldBeFlagged: Bool) async {
        let grouping = selectedByFolder
        for uid in selectedUIDs {
            applyOptimisticFlag(uid: uid, flag: .flagged, add: shouldBeFlagged)
        }
        for (source, uids) in grouping {
            try? await client.imapClient.setFlags(
                folder: source,
                uids: uids,
                flags: [.flagged],
                operation: shouldBeFlagged ? .add : .remove
            )
        }
        exitBulkMode()
    }

    private func performBulkMove(to destination: String, markSeenFirst: Bool) async {
        // The optimistic prune / unread bookkeeping / per-source revert all
        // live in the shared `performMove` (also used by drag-and-drop); the
        // bulk path just supplies the grouped selection and exits edit mode.
        await performMove(uidsBySource: selectedByFolder, to: destination, markSeenFirst: markSeenFirst)
        exitBulkMode()
    }
}

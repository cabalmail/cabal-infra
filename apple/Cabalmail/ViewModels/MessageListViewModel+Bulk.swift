import Foundation
import CabalmailKit

// Multi-select / UID-set action plumbing. Lives in a sibling extension
// so the main view-model file stays under SwiftLint's 400-line cap.
// The UID-set primitives (`setSeen(_:uids:)`, `setFlagged(_:uids:)`,
// `moveMessages(uids:to:)`, `disposeMessages(uids:action:)`) serve the
// bulk-action bar, the selection context menu, and the keyboard
// shortcuts; each is a thin wrapper over the existing UID-array wire
// calls (`setFlags(uids:)`, `move(uids:)`) plus optimistic in-memory
// updates that mirror the per-row flows. Cross-folder search results
// are grouped by source mailbox before the wire call so the server-
// side move/store routes the UIDs correctly.
//
// Selection lifetime: flag toggles (seen / flagged) leave the selection
// alone so the user can chain operations on the same messages; moves
// and disposes drop exactly the moved UIDs, since those rows are gone.
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

    /// Group an arbitrary UID set by source folder. Single-folder mode
    /// and folder-scoped searches collapse to one bucket; cross-folder
    /// search results may produce several.
    private func groupedByFolder(_ uids: Set<UInt32>) -> [String: [UInt32]] {
        let chosen = envelopes.filter { uids.contains($0.uid) }
        return Dictionary(grouping: chosen, by: { sourceFolder(for: $0) })
            .mapValues { $0.map(\.uid) }
    }

    /// Bulk equivalent of `dispose(_:)`, scoped to the selection and to
    /// the configured dispose destination. Exits edit mode — the rows
    /// are gone, so the action bar has nothing left to act on.
    func bulkDispose() async {
        await disposeMessages(uids: selectedUIDs, action: preferences.disposeAction)
        exitBulkMode()
    }

    /// Bulk equivalent of `moveTo(_:destination:)`, scoped to the
    /// selection. Exits edit mode like `bulkDispose()`.
    func bulkMove(to destination: String) async {
        await moveMessages(uids: selectedUIDs, to: destination)
        exitBulkMode()
    }

    /// Selection-scoped wrappers for the action bar. Unlike the move /
    /// dispose paths these deliberately do NOT exit edit mode: the rows
    /// are still on screen, and keeping the selection lets the user
    /// chain another action (flag, move) onto the same messages.
    func bulkSetSeen(_ shouldBeSeen: Bool) async {
        await setSeen(shouldBeSeen, uids: selectedUIDs)
    }

    func bulkSetFlagged(_ shouldBeFlagged: Bool) async {
        await setFlagged(shouldBeFlagged, uids: selectedUIDs)
    }

    /// \Seen / unset-\Seen for an explicit UID set. Walks the set per-
    /// source-folder. Optimistically updates the in-memory flags so the
    /// row styling flips before the wire call lands. Leaves any active
    /// selection intact.
    func setSeen(_ shouldBeSeen: Bool, uids: Set<UInt32>) async {
        let grouping = groupedByFolder(uids)
        // Unread badge tracking — count actual transitions per folder
        // BEFORE the optimistic loop rewrites the flags: marking an
        // already-read message read must not move the sidebar counter.
        let transitionsByFolder = Dictionary(
            grouping: envelopes.filter {
                uids.contains($0.uid) && $0.flags.contains(.seen) != shouldBeSeen
            },
            by: { sourceFolder(for: $0) }
        ).mapValues(\.count)
        for uid in uids {
            applyOptimisticFlag(uid: uid, flag: .seen, add: shouldBeSeen)
        }
        pendingFlagUIDs.formUnion(uids)
        defer { pendingFlagUIDs.subtract(uids) }
        for (source, groupUIDs) in grouping {
            try? await client.imapClient.setFlags(
                folder: source,
                uids: groupUIDs,
                flags: [.seen],
                operation: shouldBeSeen ? .add : .remove
            )
            if let transitions = transitionsByFolder[source], transitions > 0 {
                appState.applyUnreadDelta(
                    folderPath: source,
                    delta: shouldBeSeen ? -transitions : transitions
                )
            }
        }
    }

    /// Flag toggle for an explicit UID set. Mirrors `setSeen` minus the
    /// unread-count bookkeeping (flagged isn't a count we surface in
    /// the sidebar).
    func setFlagged(_ shouldBeFlagged: Bool, uids: Set<UInt32>) async {
        let grouping = groupedByFolder(uids)
        for uid in uids {
            applyOptimisticFlag(uid: uid, flag: .flagged, add: shouldBeFlagged)
        }
        pendingFlagUIDs.formUnion(uids)
        defer { pendingFlagUIDs.subtract(uids) }
        for (source, groupUIDs) in grouping {
            try? await client.imapClient.setFlags(
                folder: source,
                uids: groupUIDs,
                flags: [.flagged],
                operation: shouldBeFlagged ? .add : .remove
            )
        }
    }

    /// Move an explicit UID set. The optimistic prune / unread
    /// bookkeeping / per-source revert all live in the shared
    /// `performMove` (also used by drag-and-drop). Moved UIDs drop out
    /// of any active selection; UIDs outside the set stay selected, so
    /// a context-menu move on an unselected row leaves the user's
    /// selection alone.
    func moveMessages(uids: Set<UInt32>, to destination: String) async {
        await performMove(uidsBySource: groupedByFolder(uids), to: destination, markSeenFirst: false)
        selectedUIDs.subtract(uids)
    }

    /// Archive or trash an explicit UID set. `action` is a parameter
    /// rather than the dispose preference so the context menu can offer
    /// both destinations side by side; marks `\Seen` first to match the
    /// single-row dispose (archived == read).
    func disposeMessages(uids: Set<UInt32>, action: DisposeAction) async {
        await performMove(
            uidsBySource: groupedByFolder(uids),
            to: action.destinationFolder,
            markSeenFirst: true
        )
        selectedUIDs.subtract(uids)
    }
}

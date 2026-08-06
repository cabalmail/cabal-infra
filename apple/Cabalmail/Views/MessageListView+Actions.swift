import SwiftUI
import CabalmailKit

/// UID set captured for a "Move to folder…" sheet driven by the
/// selection context menu or the Cmd+M shortcut. Identifiable wrapper
/// so `.sheet(item:)` reuses the same presentation machinery as
/// `envelopeToMove`; the id is per-presentation, never read beyond it.
struct SelectionMoveCandidate: Identifiable {
    let uids: Set<UInt32>
    let id = UUID()
}

/// UID set staged for the "Delete Forever?" confirmation inside Trash —
/// a one-element set from the row swipe / menu, the whole selection from
/// the selection menu, action bar, or Cmd+Delete. Identifiable for the
/// same reason as `SelectionMoveCandidate`.
struct PurgeCandidate: Identifiable {
    let uids: Set<UInt32>
    let id = UUID()
}

/// UID set staged for the large-selection dispose confirmation: an
/// archive/trash dispose of `largeDisposeThreshold`-or-more messages
/// pauses on an "are you sure" dialog before it runs (Phase 3 of
/// docs/0.11.x/multi-select-bulk-operations.md). Smaller disposes commit
/// immediately, and non-destructive bulk ops (move, flag, read) never
/// confirm at any size.
struct DisposeCandidate: Identifiable {
    let uids: Set<UInt32>
    let action: DisposeAction
    /// Leave selection / edit mode once the dispose commits — set by the
    /// bulk action bar, whose flow ends with the bar dismissing. The
    /// context menu and Cmd+Delete leave the mode as the user had it.
    let exitBulk: Bool
    let id = UUID()
}

// Selection-scoped actions for `MessageListView`'s wide/keyboard
// layouts (macOS, iPad regular, visionOS): the List-level context menu
// that acts on the whole multi-selection, and the handlers behind the
// Message-menu chords (Cmd+T read/unread, Cmd+Shift+8 flag, Cmd+M move)
// and the Delete-key dispose. Lives in a sibling extension so the
// primary view body stays under SwiftLint's caps, matching `+Rows` /
// `+Bulk` / `+Selection`.
extension MessageListView {
    /// Menu for the List-level `contextMenu(forSelectionType:)` on wide
    /// layouts. SwiftUI hands us the set the click landed on: the whole
    /// selection when a selected row is right-clicked, just the clicked
    /// row when it isn't part of the selection — Finder / Mail
    /// semantics for free. Read/unread and flag leave the selection
    /// intact (see the selection-lifetime note in
    /// `MessageListViewModel+Bulk.swift`); both dispose destinations
    /// are offered, not just the configured default.
    @ViewBuilder
    func selectionContextMenu(
        for uids: Set<UInt32>,
        model: MessageListViewModel
    ) -> some View {
        if !uids.isEmpty {
            let chosen = model.envelopes.filter { uids.contains($0.uid) }
            let hasUnflagged = chosen.contains { !$0.flags.contains(.flagged) }
            let hasUnread = chosen.contains { !$0.flags.contains(.seen) }
            Button {
                Task { await model.setFlagged(hasUnflagged, uids: uids) }
            } label: {
                Label(
                    hasUnflagged ? "Flag" : "Unflag",
                    systemImage: hasUnflagged ? "flag" : "flag.slash"
                )
            }
            Button {
                Task { await model.setSeen(hasUnread, uids: uids) }
            } label: {
                Label(
                    hasUnread ? "Mark as Read" : "Mark as Unread",
                    systemImage: hasUnread ? "envelope.open" : "envelope.badge"
                )
            }
            Button {
                moveCandidate = SelectionMoveCandidate(uids: uids)
            } label: {
                Label("Move to folder…", systemImage: "folder")
            }
            selectionDisposeItems(for: uids, model: model)
        }
    }

    /// The menu's two dispose items, split out to keep
    /// `selectionContextMenu` under SwiftLint's body-length cap.
    @ViewBuilder
    private func selectionDisposeItems(
        for uids: Set<UInt32>,
        model: MessageListViewModel
    ) -> some View {
        // Inside Archive the archive item has nowhere to send the
        // selection, so it restores to the inbox instead — a plain
        // move, hence no large-selection confirmation.
        if model.archiveIntent == .restore {
            Button {
                restoreSelection(uids: uids, model: model)
            } label: {
                restoreActionLabel
            }
        } else {
            Button {
                requestDispose(uids: uids, action: .archive, exitBulk: false, model: model)
            } label: {
                Label("Archive", systemImage: "archivebox")
            }
        }
        // Inside Trash "move to Trash" is meaningless: delete means
        // gone forever, so the destructive item stages the same
        // confirmation as the row swipe, for the whole set.
        if model.isTrashFolder {
            Button(role: .destructive) {
                purgeCandidate = PurgeCandidate(uids: uids)
            } label: {
                purgeActionLabel
            }
        } else {
            Button(role: .destructive) {
                requestDispose(uids: uids, action: .trash, exitBulk: false, model: model)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    /// Destination picker for a context-menu / Cmd+M move. Mirrors
    /// `bulkMoveSheet` but carries its own UID set, so a move invoked
    /// on a right-clicked-but-unselected row doesn't drag the user's
    /// selection along with it.
    @ViewBuilder
    func selectionMoveSheet(for candidate: SelectionMoveCandidate) -> some View {
        if let client = appState.client {
            MoveToFolderSheet(
                currentFolder: folder,
                client: client,
                onSelect: { destination in
                    moveCandidate = nil
                    if let model {
                        Task { await model.moveMessages(uids: candidate.uids, to: destination.path) }
                    }
                },
                onCancel: { moveCandidate = nil }
            )
        }
    }

    /// The messages a Message-menu chord should act on: the multi-
    /// select set when one exists (wide layouts put even a plain single
    /// click here), else the reading-pane selection (compact iPhone
    /// with a hardware keyboard), else nothing — the menu bump no-ops,
    /// matching the Reply-with-no-message convention.
    private func shortcutTargetUIDs(model: MessageListViewModel) -> Set<UInt32> {
        if !model.selectedUIDs.isEmpty { return model.selectedUIDs }
        if let selection { return [selection.uid] }
        return []
    }

    /// Cmd+T. Mixed selections resolve like the bulk bar: any unread
    /// message means "mark all read", otherwise "mark all unread".
    func toggleSeenOnSelection(model: MessageListViewModel) {
        let uids = shortcutTargetUIDs(model: model)
        guard !uids.isEmpty else { return }
        let hasUnread = model.envelopes.contains {
            uids.contains($0.uid) && !$0.flags.contains(.seen)
        }
        Task { await model.setSeen(hasUnread, uids: uids) }
    }

    /// Cmd+Shift+8 (Cmd+*). Any unflagged message means "flag all",
    /// otherwise "unflag all".
    func toggleFlaggedOnSelection(model: MessageListViewModel) {
        let uids = shortcutTargetUIDs(model: model)
        guard !uids.isEmpty else { return }
        let hasUnflagged = model.envelopes.contains {
            uids.contains($0.uid) && !$0.flags.contains(.flagged)
        }
        Task { await model.setFlagged(hasUnflagged, uids: uids) }
    }

    /// Cmd+M. Opens the destination picker for the current selection.
    func moveSelection(model: MessageListViewModel) {
        let uids = shortcutTargetUIDs(model: model)
        guard !uids.isEmpty else { return }
        moveCandidate = SelectionMoveCandidate(uids: uids)
    }

    /// Cmd+Delete with a multi-selection, fired by the invisible window-
    /// scoped equivalent in `wideList` (a single selection's Cmd+Delete
    /// belongs to the detail toolbar's dispose button). Honors the
    /// dispose preference (Archive or Trash), same as the trailing
    /// swipe — including that swipe's folder-specific cases: inside
    /// Trash it stages the delete-forever confirmation like every other
    /// purge surface, and inside Archive it restores.
    func disposeSelection(model: MessageListViewModel) {
        let uids = shortcutTargetUIDs(model: model)
        guard !uids.isEmpty else { return }
        switch model.disposeIntent {
        case .purge:
            purgeCandidate = PurgeCandidate(uids: uids)
        case .restore:
            restoreSelection(uids: uids, model: model)
        case .move(let action):
            requestDispose(uids: uids, action: action, exitBulk: false, model: model)
        }
    }

    /// Move a selection back to the inbox — the Archive folder's stand-in
    /// for archiving it. A restore takes nothing away from the user, so it
    /// commits straight through rather than routing via `requestDispose`'s
    /// large-selection confirmation, and it carries unread state with the
    /// messages instead of marking them `\Seen`.
    func restoreSelection(uids: Set<UInt32>, model: MessageListViewModel) {
        guard !uids.isEmpty else { return }
        Task { await model.moveMessages(uids: uids, to: FolderTree.inboxPath) }
    }

    /// Selection size at which a dispose asks first. Large enough that
    /// routine triage never sees the dialog; small enough that a
    /// mis-aimed select-all can't silently file hundreds of messages.
    static var largeDisposeThreshold: Int { 25 }

    /// Routes every non-Trash dispose surface (action bar, selection
    /// context menu, Cmd+Delete): a large selection stages the
    /// confirmation dialog, a small one commits immediately.
    func requestDispose(
        uids: Set<UInt32>,
        action: DisposeAction,
        exitBulk: Bool,
        model: MessageListViewModel
    ) {
        guard !uids.isEmpty else { return }
        let candidate = DisposeCandidate(uids: uids, action: action, exitBulk: exitBulk)
        if uids.count >= Self.largeDisposeThreshold {
            disposeCandidate = candidate
        } else {
            commitDispose(candidate, model: model)
        }
    }

    /// Runs a staged (or immediately-committed) dispose. Selection /
    /// edit mode drops right away when requested — the candidate holds
    /// its own UID copy, so clearing the live selection is safe.
    func commitDispose(_ candidate: DisposeCandidate, model: MessageListViewModel) {
        Task { await model.disposeMessages(uids: candidate.uids, action: candidate.action) }
        if candidate.exitBulk {
            model.exitBulkMode()
            endSelectionMode()
        }
    }
}

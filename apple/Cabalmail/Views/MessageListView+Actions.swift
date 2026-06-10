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
            Button {
                Task { await model.disposeMessages(uids: uids, action: .archive) }
            } label: {
                Label("Archive", systemImage: "archivebox")
            }
            Button(role: .destructive) {
                Task { await model.disposeMessages(uids: uids, action: .trash) }
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
    /// dispose preference (Archive or Trash), same as the trailing swipe.
    func disposeSelection(model: MessageListViewModel) {
        let uids = shortcutTargetUIDs(model: model)
        guard !uids.isEmpty else { return }
        let action = model.disposeAction
        Task { await model.disposeMessages(uids: uids, action: action) }
    }
}

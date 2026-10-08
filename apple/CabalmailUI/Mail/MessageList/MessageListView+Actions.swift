import SwiftUI
import CabalmailKit

/// Messages captured for a "Move to folder…" sheet driven by the
/// selection context menu or the Cmd+M shortcut. Identifiable wrapper
/// so `.sheet(item:)` reuses the same presentation machinery as
/// `envelopeToMove`; the id is per-presentation, never read beyond it.
struct SelectionMoveCandidate: Identifiable {
    let refs: Set<MessageRef>
    let id = UUID()
}

/// Messages staged for the "Delete Forever?" confirmation inside Trash —
/// a one-element set from the row swipe / menu, the whole selection from
/// the selection menu, action bar, or Cmd+Delete. Identifiable for the
/// same reason as `SelectionMoveCandidate`.
struct PurgeCandidate: Identifiable {
    let refs: Set<MessageRef>
    let id = UUID()
}

/// Messages staged for the large-selection dispose confirmation: an
/// archive/trash dispose of `largeDisposeThreshold`-or-more messages
/// pauses on an "are you sure" dialog before it runs (Phase 3 of
/// docs/0.11.x/multi-select-bulk-operations.md). Smaller disposes commit
/// immediately, and non-destructive bulk ops (move, flag, read) never
/// confirm at any size.
struct DisposeCandidate: Identifiable {
    let refs: Set<MessageRef>
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
        for refs: Set<MessageRef>,
        model: MessageListViewModel
    ) -> some View {
        if !refs.isEmpty {
            let chosen = model.loadedRows(refs)
            let hasUnflagged = chosen.contains { !$0.flags.contains(.flagged) }
            let hasUnread = chosen.contains { !$0.flags.contains(.seen) }
            Button {
                Task { await model.setFlagged(hasUnflagged, refs: refs) }
            } label: {
                Label(
                    hasUnflagged ? "Flag" : "Unflag",
                    systemImage: hasUnflagged ? "flag" : "flag.slash"
                )
            }
            Button {
                Task { await model.setSeen(hasUnread, refs: refs) }
            } label: {
                Label(
                    hasUnread ? "Mark as Read" : "Mark as Unread",
                    systemImage: hasUnread ? "envelope.open" : "envelope.badge"
                )
            }
            Button {
                moveCandidate = SelectionMoveCandidate(refs: refs)
            } label: {
                Label("Move to folder…", systemImage: "folder")
            }
            selectionDisposeItems(for: refs, model: model)
        }
    }

    /// The menu's two dispose items, split out to keep
    /// `selectionContextMenu` under SwiftLint's body-length cap.
    @ViewBuilder
    private func selectionDisposeItems(
        for refs: Set<MessageRef>,
        model: MessageListViewModel
    ) -> some View {
        // Inside Archive the archive item has nowhere to send the
        // selection, so it restores to the inbox instead — a plain
        // move, hence no large-selection confirmation.
        if model.archiveIntent == .restore {
            Button {
                restoreSelection(refs: refs, model: model)
            } label: {
                restoreActionLabel
            }
        } else {
            Button {
                requestDispose(refs: refs, action: .archive, exitBulk: false, model: model)
            } label: {
                Label("Archive", systemImage: "archivebox")
            }
        }
        // Inside Trash "move to Trash" is meaningless: delete means
        // gone forever, so the destructive item stages the same
        // confirmation as the row swipe, for the whole set.
        if model.isTrashFolder {
            Button(role: .destructive) {
                purgeCandidate = PurgeCandidate(refs: refs)
            } label: {
                purgeActionLabel
            }
        } else {
            Button(role: .destructive) {
                requestDispose(refs: refs, action: .trash, exitBulk: false, model: model)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    /// Destination picker for a context-menu / Cmd+M move. Mirrors
    /// `bulkMoveSheet` but carries its own messages, so a move invoked
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
                        Task { await model.moveMessages(refs: candidate.refs, to: destination.path) }
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
    private func shortcutTargetRefs(model: MessageListViewModel) -> Set<MessageRef> {
        if !model.selectedRefs.isEmpty { return model.selectedRefs }
        if let selection { return [model.rowRef(for: selection)] }
        return []
    }

    /// Cmd+T. Mixed selections resolve like the bulk bar: any unread
    /// message means "mark all read", otherwise "mark all unread".
    func toggleSeenOnSelection(model: MessageListViewModel) {
        let refs = shortcutTargetRefs(model: model)
        guard !refs.isEmpty else { return }
        let hasUnread = model.loadedRows(refs).contains { !$0.flags.contains(.seen) }
        Task { await model.setSeen(hasUnread, refs: refs) }
    }

    /// Cmd+Shift+8 (Cmd+*). Any unflagged message means "flag all",
    /// otherwise "unflag all".
    func toggleFlaggedOnSelection(model: MessageListViewModel) {
        let refs = shortcutTargetRefs(model: model)
        guard !refs.isEmpty else { return }
        let hasUnflagged = model.loadedRows(refs).contains { !$0.flags.contains(.flagged) }
        Task { await model.setFlagged(hasUnflagged, refs: refs) }
    }

    /// Cmd+M. Opens the destination picker for the current selection.
    func moveSelection(model: MessageListViewModel) {
        let refs = shortcutTargetRefs(model: model)
        guard !refs.isEmpty else { return }
        moveCandidate = SelectionMoveCandidate(refs: refs)
    }

    /// Cmd+Delete with a multi-selection, fired by the invisible window-
    /// scoped equivalent in `wideList` (a single selection's Cmd+Delete
    /// belongs to the detail toolbar's dispose button). Honors the
    /// dispose preference (Archive or Trash), same as the trailing
    /// swipe — including that swipe's folder-specific cases: inside
    /// Trash it stages the delete-forever confirmation like every other
    /// purge surface, and inside Archive it restores.
    func disposeSelection(model: MessageListViewModel) {
        let refs = shortcutTargetRefs(model: model)
        guard !refs.isEmpty else { return }
        switch model.disposeIntent {
        case .purge:
            purgeCandidate = PurgeCandidate(refs: refs)
        case .restore:
            restoreSelection(refs: refs, model: model)
        case .move(let action):
            requestDispose(refs: refs, action: action, exitBulk: false, model: model)
        }
    }

    /// Move a selection back to the inbox — the Archive folder's stand-in
    /// for archiving it. A restore takes nothing away from the user, so it
    /// commits straight through rather than routing via `requestDispose`'s
    /// large-selection confirmation, and it carries unread state with the
    /// messages instead of marking them `\Seen`.
    func restoreSelection(refs: Set<MessageRef>, model: MessageListViewModel) {
        guard !refs.isEmpty else { return }
        Task { await model.moveMessages(refs: refs, to: FolderTree.inboxPath) }
    }

    /// Selection size at which a dispose asks first. Large enough that
    /// routine triage never sees the dialog; small enough that a
    /// mis-aimed select-all can't silently file hundreds of messages.
    static var largeDisposeThreshold: Int { 25 }

    /// Routes every non-Trash dispose surface (action bar, selection
    /// context menu, Cmd+Delete): a large selection stages the
    /// confirmation dialog, a small one commits immediately.
    func requestDispose(
        refs: Set<MessageRef>,
        action: DisposeAction,
        exitBulk: Bool,
        model: MessageListViewModel
    ) {
        guard !refs.isEmpty else { return }
        let candidate = DisposeCandidate(refs: refs, action: action, exitBulk: exitBulk)
        if refs.count >= Self.largeDisposeThreshold {
            disposeCandidate = candidate
        } else {
            commitDispose(candidate, model: model)
        }
    }

    /// Runs a staged (or immediately-committed) dispose. Selection /
    /// edit mode drops right away when requested — the candidate holds
    /// its own copy of the refs, so clearing the live selection is safe.
    func commitDispose(_ candidate: DisposeCandidate, model: MessageListViewModel) {
        Task { await model.disposeMessages(refs: candidate.refs, action: candidate.action) }
        if candidate.exitBulk {
            model.exitBulkMode()
            endSelectionMode()
        }
    }

    /// Applies what the mail events this list heard ask of its selection,
    /// oldest first, from where this view left off
    /// (`MessageListViewModel.selectionReactions`), per
    /// `MailEventSelectionPolicy`: a reader action moves only its own
    /// window's selection, and every other window's list just lets go of the
    /// row (#1845). Wide layouts drive the reading pane off `selectedRefs`;
    /// compact moves `selection`. A target the list no longer holds (a
    /// refresh moved its window on) lets the reader go.
    func applySelectionReactions(model: MessageListViewModel) {
        let reactions = model.selectionReactions.since(appliedSelectionReactions)
        appliedSelectionReactions = model.selectionReactions.tick
        guard let update = MailEventSelectionPolicy.update(
            after: reactions,
            selectedRefs: model.selectedRefs,
            shown: selection.map(model.rowRef(for:)),
            isWideLayout: isWideLayout,
            in: commandWindowID
        ) else { return }
        let shown = update.shown.flatMap(model.envelope(for:))
        if isWideLayout {
            model.selectedRefs = update.shown != nil && shown == nil ? [] : update.selectedRefs
        }
        selection = shown
    }
}

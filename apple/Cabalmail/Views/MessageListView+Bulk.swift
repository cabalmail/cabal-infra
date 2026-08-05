import SwiftUI
import CabalmailKit

// Multi-select UI: a Select toolbar button that flips edit mode, a
// bottom action bar that surfaces the bulk operations, and a Move
// destination sheet. Lives in a sibling extension so MessageListView's
// primary body stays under SwiftLint's `type_body_length` cap.
extension MessageListView {
    /// Toolbar item that flips the multi-select mode. Reads "Select" when off
    /// and "Done" while on, matching every other iOS list-edit affordance.
    ///
    /// macOS multi-selects via pointer modifier-clicks (shift / command)
    /// directly in the list, so it shows no button. Every touch layout —
    /// compact iPhone and wide iPad / visionOS alike — drives the view model's
    /// `bulkMode`: the rows are a hand-rolled `LazyVStack`, so there is no
    /// native list EditMode to enter, and view-local `@State` would not
    /// survive the split view rebuilding its content column.
    @ViewBuilder
    var selectButton: some View {
        #if os(macOS)
        EmptyView()
        #else
        if let model {
            Button {
                model.toggleBulkMode()
            } label: {
                if model.bulkMode {
                    Text("Done")
                } else {
                    Image(systemName: "checkmark.circle")
                        .accessibilityLabel("Select")
                }
            }
            .accessibilityIdentifier("list.select")
        }
        #endif
    }

    /// Called when a bulk move / dispose commits — the actions that remove
    /// the selected rows. Drops the mode so the action bar dismisses; the
    /// action itself clears `selectedUIDs` once its async body has read them
    /// (`leaveBulkMode` deliberately leaves the set alone, since this runs
    /// before the `Task` that does the moving). The read/unread and flag
    /// buttons deliberately skip it: their rows stay on screen, and keeping
    /// the selection lets the user chain another action onto the same
    /// messages. Internal (not private) so `commitDispose` in
    /// `+Actions.swift` can drop the mode after a confirmed large dispose.
    func endSelectionMode() {
        model?.leaveBulkMode()
    }

    /// Bottom action bar rendered in `safeAreaInset` while bulkMode is
    /// active. Mirrors React's bulk-mode pill row (Archive / Move /
    /// Delete / Mark Read/Unread / Flag).
    @ViewBuilder
    func bulkActionBar(model: MessageListViewModel) -> some View {
        let count = model.selectedUIDs.count
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 14) {
                Text("\(count) selected")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
                bulkActionButtons(model: model, count: count)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.bar)
        }
        .disabled(count == 0)
    }

    /// The action buttons themselves — split from `bulkActionBar` to keep
    /// each function under SwiftLint's body-length cap.
    @ViewBuilder
    private func bulkActionButtons(model: MessageListViewModel, count: Int) -> some View {
        let hasUnread = bulkSelectionContainsUnread(model)
        let hasUnflagged = bulkSelectionContainsUnflagged(model)
        let restoring = model.archiveIntent == .restore
        bulkActionButton(
            systemImage: restoring ? restoreSymbol : "archivebox",
            label: restoring ? "Restore" : "Archive",
            accessibilityLabel: "\(restoring ? "Restore" : "Archive") \(messageCount(count))",
            identifier: "bulk.archive"
        ) {
            bulkArchive(model: model)
        }
        bulkActionButton(
            systemImage: "folder",
            label: "Move…",
            accessibilityLabel: "Move \(messageCount(count))",
            identifier: "bulk.move"
        ) {
            bulkMoveSheetPresented = true
        }
        bulkActionButton(
            systemImage: hasUnread ? "envelope.open" : "envelope.badge",
            label: hasUnread ? "Read" : "Unread",
            accessibilityLabel: "Mark \(messageCount(count)) \(hasUnread ? "read" : "unread")",
            identifier: "bulk.toggleRead"
        ) {
            Task { await model.bulkSetSeen(hasUnread) }
        }
        bulkActionButton(
            systemImage: hasUnflagged ? "flag" : "flag.slash",
            label: hasUnflagged ? "Flag" : "Unflag",
            accessibilityLabel: "\(hasUnflagged ? "Flag" : "Unflag") \(messageCount(count))",
            identifier: "bulk.toggleFlag"
        ) {
            Task { await model.bulkSetFlagged(hasUnflagged) }
        }
        // Trash only: permanent delete for the whole selection, behind
        // the same "Delete Forever?" confirmation as the row swipe.
        if model.isTrashFolder {
            bulkActionButton(
                systemImage: "trash.slash",
                label: "Delete",
                role: .destructive,
                accessibilityLabel: "Delete \(messageCount(count)) forever",
                identifier: "bulk.delete"
            ) {
                purgeCandidate = PurgeCandidate(uids: model.selectedUIDs)
            }
        }
    }

    /// The bar's Archive action. Inside Trash the dispose preference may
    /// point back at Trash itself (a same-folder no-op); Archive on this
    /// bar is the rescue path, so send the selection to the real Archive
    /// folder there. Inside Archive the button restores instead — an
    /// archive would move the selection onto its own folder. Both are
    /// plain moves (non-destructive), so they skip the large-selection
    /// confirmation that requestDispose applies.
    private func bulkArchive(model: MessageListViewModel) {
        switch model.archiveIntent {
        case .restore:
            restoreSelection(uids: model.selectedUIDs, model: model)
            endSelectionMode()
        default:
            if model.isTrashFolder {
                Task { await model.bulkMove(to: DisposeAction.archive.destinationFolder) }
                endSelectionMode()
            } else {
                requestDispose(
                    uids: model.selectedUIDs,
                    action: model.disposeAction,
                    exitBulk: true,
                    model: model
                )
            }
        }
    }

    /// "12 messages" / "1 message" — the count phrase VoiceOver reads on
    /// every bulk action button, so "Archive" is announced as "Archive 12
    /// messages" rather than a bare verb with no scope.
    private func messageCount(_ count: Int) -> String {
        count == 1 ? "1 message" : "\(count) messages"
    }

    @ViewBuilder
    private func bulkActionButton(
        systemImage: String,
        label: String,
        role: ButtonRole? = nil,
        accessibilityLabel: String? = nil,
        identifier: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            VStack(spacing: 2) {
                Image(systemName: systemImage)
                Text(label)
                    .font(.caption2)
            }
        }
        .buttonStyle(.plain)
        // `.plain` drops the automatic destructive tinting, so red is
        // applied explicitly for destructive roles.
        .foregroundStyle(role == .destructive ? AnyShapeStyle(.red) : AnyShapeStyle(.tint))
        .accessibilityLabel(accessibilityLabel ?? label)
        .accessibilityIdentifier(identifier ?? "")
    }

    @ViewBuilder
    func bulkMoveSheet(model: MessageListViewModel) -> some View {
        if let client = appState.client {
            MoveToFolderSheet(
                currentFolder: folder,
                client: client,
                onSelect: { destination in
                    bulkMoveSheetPresented = false
                    Task { await model.bulkMove(to: destination.path) }
                    endSelectionMode()
                },
                onCancel: { bulkMoveSheetPresented = false }
            )
        }
    }

    /// True iff at least one selected envelope is unread — drives the
    /// "Read" vs "Unread" label on the toolbar button so the action
    /// always matches the majority intent.
    private func bulkSelectionContainsUnread(_ model: MessageListViewModel) -> Bool {
        model.envelopes.contains { envelope in
            model.selectedUIDs.contains(envelope.uid)
                && !envelope.flags.contains(.seen)
        }
    }

    private func bulkSelectionContainsUnflagged(_ model: MessageListViewModel) -> Bool {
        model.envelopes.contains { envelope in
            model.selectedUIDs.contains(envelope.uid)
                && !envelope.flags.contains(.flagged)
        }
    }
}

import SwiftUI
import CabalmailKit

// Multi-select UI: a Select toolbar button that flips edit mode, a
// bottom action bar that surfaces the bulk operations, and a Move
// destination sheet. Lives in a sibling extension so MessageListView's
// primary body stays under SwiftLint's `type_body_length` cap.
extension MessageListView {
    /// Toolbar item that flips edit mode. Reads "Select" when off and
    /// "Done" while on, matching every other iOS list-edit affordance.
    ///
    /// macOS multi-selects via pointer modifier-clicks (shift / command)
    /// directly in the list, so it shows no button. iPad / visionOS toggle the
    /// native list EditMode so touch users can multi-select without a keyboard;
    /// compact iPhone keeps the legacy `bulkMode` checkbox flow.
    @ViewBuilder
    var selectButton: some View {
        #if os(macOS)
        EmptyView()
        #else
        if let model {
            if isWideLayout {
                Button {
                    toggleSelectionEditMode(model: model)
                } label: {
                    if editMode == .active {
                        Text("Done")
                    } else {
                        Image(systemName: "checkmark.circle")
                            .accessibilityLabel("Select")
                    }
                }
            } else {
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
            }
        }
        #endif
    }

    #if !os(macOS)
    /// Enter / leave the native multi-select EditMode on wide touch layouts.
    /// Leaving clears the selection so re-entering starts fresh, mirroring
    /// `toggleBulkMode()`'s contract on compact.
    private func toggleSelectionEditMode(model: MessageListViewModel) {
        if editMode == .active {
            editMode = .inactive
            model.selectedUIDs.removeAll()
        } else {
            editMode = .active
        }
    }
    #endif

    /// Called when a bulk move / dispose commits — the actions that remove
    /// the selected rows. The action itself clears `selectedUIDs` (via
    /// `exitBulkMode()`); this additionally drops any touch EditMode so the
    /// action bar dismisses on iPad / visionOS. No-op on macOS, which has no
    /// EditMode. The read/unread and flag buttons deliberately skip it:
    /// their rows stay on screen, and keeping the selection lets the user
    /// chain another action onto the same messages. Internal (not private)
    /// so `commitDispose` in `+Actions.swift` can drop the mode after a
    /// confirmed large dispose.
    func endSelectionMode() {
        #if !os(macOS)
        editMode = .inactive
        #endif
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
        bulkActionButton(
            systemImage: "archivebox",
            label: "Archive",
            accessibilityLabel: "Archive \(messageCount(count))"
        ) {
            // Inside Trash the dispose preference may point back at Trash
            // itself (a same-folder no-op); Archive on this bar is the
            // rescue path, so send the selection to the real Archive
            // folder there. Rescue is a plain move (non-destructive), so
            // it skips the large-selection confirmation that
            // requestDispose applies.
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
        bulkActionButton(
            systemImage: "folder",
            label: "Move…",
            accessibilityLabel: "Move \(messageCount(count))"
        ) {
            bulkMoveSheetPresented = true
        }
        bulkActionButton(
            systemImage: hasUnread ? "envelope.open" : "envelope.badge",
            label: hasUnread ? "Read" : "Unread",
            accessibilityLabel: "Mark \(messageCount(count)) \(hasUnread ? "read" : "unread")"
        ) {
            Task { await model.bulkSetSeen(hasUnread) }
        }
        bulkActionButton(
            systemImage: hasUnflagged ? "flag" : "flag.slash",
            label: hasUnflagged ? "Flag" : "Unflag",
            accessibilityLabel: "\(hasUnflagged ? "Flag" : "Unflag") \(messageCount(count))"
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
                accessibilityLabel: "Delete \(messageCount(count)) forever"
            ) {
                purgeCandidate = PurgeCandidate(uids: model.selectedUIDs)
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

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
            // Widest row that fits the message-list column, which is far
            // narrower than the window on macOS — see BulkActionBarLayout
            // for why the bar sheds elements rather than letting the
            // captions hyphenate.
            ViewThatFits(in: .horizontal) {
                bulkActionRow(model: model, count: count, layout: .full)
                bulkActionRow(model: model, count: count, layout: .captionsOnly)
                bulkActionRow(model: model, count: count, layout: .glyphsOnly)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.bar)
        }
        .disabled(count == 0)
    }

    /// One rung of the ladder. The buttons stay trailing-aligned whether or
    /// not the count is drawn, so dropping it doesn't shift them.
    @ViewBuilder
    private func bulkActionRow(
        model: MessageListViewModel,
        count: Int,
        layout: BulkActionBarLayout
    ) -> some View {
        HStack(spacing: 14) {
            if layout.showsCount {
                Text("\(count) selected")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: true, vertical: false)
            }
            Spacer(minLength: 0)
            bulkActionButtons(model: model, count: count, showsCaptions: layout.showsCaptions)
        }
    }

    /// The action buttons themselves — split from `bulkActionBar` to keep
    /// each function under SwiftLint's body-length cap.
    @ViewBuilder
    private func bulkActionButtons(
        model: MessageListViewModel,
        count: Int,
        showsCaptions: Bool
    ) -> some View {
        let hasUnread = bulkSelectionContainsUnread(model)
        let hasUnflagged = bulkSelectionContainsUnflagged(model)
        let archive = BulkArchiveButtonPolicy.button(in: model.folder.path)
        bulkActionButton(
            systemImage: archive.systemImage,
            label: archive.title,
            accessibilityLabel: "\(archive.title) \(messageCount(count))",
            identifier: "bulk.archive",
            showsCaption: showsCaptions
        ) {
            bulkArchive(model: model, intent: archive.intent)
        }
        bulkActionButton(
            systemImage: "folder",
            label: "Move…",
            accessibilityLabel: "Move \(messageCount(count))",
            identifier: "bulk.move",
            showsCaption: showsCaptions
        ) {
            bulkMoveSheetPresented = true
        }
        bulkActionButton(
            systemImage: hasUnread ? "envelope.open" : "envelope.badge",
            label: hasUnread ? "Read" : "Unread",
            accessibilityLabel: "Mark \(messageCount(count)) \(hasUnread ? "read" : "unread")",
            identifier: "bulk.toggleRead",
            showsCaption: showsCaptions
        ) {
            Task { await model.bulkSetSeen(hasUnread) }
        }
        bulkActionButton(
            systemImage: hasUnflagged ? "flag" : "flag.slash",
            label: hasUnflagged ? "Flag" : "Unflag",
            accessibilityLabel: "\(hasUnflagged ? "Flag" : "Unflag") \(messageCount(count))",
            identifier: "bulk.toggleFlag",
            showsCaption: showsCaptions
        ) {
            Task { await model.bulkSetFlagged(hasUnflagged) }
        }
        bulkDeleteButton(model: model, count: count, showsCaptions: showsCaptions)
    }

    /// Trash only: permanent delete for the whole selection, behind the same
    /// "Delete Forever?" confirmation as the row swipe. Split out to keep
    /// `bulkActionButtons` under SwiftLint's body-length cap.
    @ViewBuilder
    private func bulkDeleteButton(
        model: MessageListViewModel,
        count: Int,
        showsCaptions: Bool
    ) -> some View {
        if model.isTrashFolder {
            bulkActionButton(
                systemImage: "trash.slash",
                label: "Delete",
                role: .destructive,
                accessibilityLabel: "Delete \(messageCount(count)) forever",
                identifier: "bulk.delete",
                showsCaption: showsCaptions
            ) {
                purgeCandidate = PurgeCandidate(uids: model.selectedUIDs)
            }
        }
    }

    /// The bar's Archive action, running the intent its caption came from
    /// (`BulkArchiveButtonPolicy`) so the two can't diverge. Inside Archive
    /// the button restores instead — an archive would move the selection
    /// onto its own folder. The remaining folder test picks the *transport*,
    /// not the destination: inside Trash this is the rescue path out of the
    /// deleted pile, a plain move that leaves unread state alone and skips
    /// the large-selection confirmation, where elsewhere an archive is an
    /// ordinary dispose.
    private func bulkArchive(model: MessageListViewModel, intent: DisposeIntent) {
        switch intent {
        case .restore:
            restoreSelection(uids: model.selectedUIDs, model: model)
            endSelectionMode()
        case .move(let action):
            if model.isTrashFolder {
                Task { await model.bulkMove(to: action.destinationFolder) }
                endSelectionMode()
            } else {
                requestDispose(
                    uids: model.selectedUIDs,
                    action: action,
                    exitBulk: true,
                    model: model
                )
            }
        case .purge:
            // `archiving(in:)` never yields a purge; the bar draws its own
            // destructive Delete for that, inside Trash only.
            break
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
        showsCaption: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            VStack(spacing: 2) {
                Image(systemName: systemImage)
                if showsCaption {
                    Text(label)
                        .font(.caption2)
                        // Keep the caption on one line; ViewThatFits reads
                        // its natural width to tell whether this rung fits,
                        // and a caption free to wrap always "fits".
                        .fixedSize(horizontal: true, vertical: false)
                }
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

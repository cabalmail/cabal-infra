import SwiftUI
import CabalmailKit

// Multi-select UI: a Select toolbar button that flips edit mode, a
// bottom action bar that surfaces the bulk operations, and a Move
// destination sheet. Lives in a sibling extension so MessageListView's
// primary body stays under SwiftLint's `type_body_length` cap.
extension MessageListView {
    /// Toolbar item that flips edit mode. Reads "Select" when off and
    /// "Done" while on, matching every other iOS list-edit affordance.
    @ViewBuilder
    var selectButton: some View {
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
        }
    }

    /// Bottom action bar rendered in `safeAreaInset` while bulkMode is
    /// active. Mirrors React's bulk-mode pill row (Archive / Move /
    /// Delete / Mark Read/Unread / Flag).
    @ViewBuilder
    func bulkActionBar(model: MessageListViewModel) -> some View {
        let count = model.selectedUIDs.count
        let hasUnread = bulkSelectionContainsUnread(model)
        let hasUnflagged = bulkSelectionContainsUnflagged(model)
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 14) {
                Text("\(count) selected")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
                bulkActionButton(systemImage: "archivebox", label: "Archive") {
                    Task { await model.bulkDispose() }
                }
                bulkActionButton(systemImage: "folder", label: "Move…") {
                    bulkMoveSheetPresented = true
                }
                bulkActionButton(
                    systemImage: hasUnread ? "envelope.open" : "envelope.badge",
                    label: hasUnread ? "Read" : "Unread"
                ) {
                    Task { await model.bulkSetSeen(hasUnread) }
                }
                bulkActionButton(
                    systemImage: hasUnflagged ? "flag" : "flag.slash",
                    label: hasUnflagged ? "Flag" : "Unflag"
                ) {
                    Task { await model.bulkSetFlagged(hasUnflagged) }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.bar)
        }
        .disabled(count == 0)
    }

    @ViewBuilder
    private func bulkActionButton(
        systemImage: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: systemImage)
                Text(label)
                    .font(.caption2)
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tint)
        .accessibilityLabel(label)
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

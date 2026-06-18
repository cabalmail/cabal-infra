import SwiftUI
import CabalmailKit

// Selection plumbing for `MessageListView`: the two `List` variants (native
// multiple selection on wide/keyboard layouts, single selection on compact
// iPhone) and the helpers that derive row state and handle the keyboard
// idioms. Lives in a sibling extension so the primary view body stays under
// SwiftLint's `type_body_length` / `file_length` caps, matching the pattern
// used by `+Rows`, `+Bulk`, `+Filter`, and `+macOS`.
extension MessageListView {
    /// Virtualized message list -- Stage A of the ScrollView rewrite. A
    /// `ScrollView` + `LazyVStack` with two blank spacer views reserving the
    /// off-window rows, so the scroll extent matches the whole folder (a true-
    /// to-size scrollbar) and each row keeps its absolute position as the
    /// window trims/reloads (no jump) -- what macOS `List` could not do with a
    /// tall spacer cell. Rows are pinned to `MessageListView.rowHeight`.
    /// Sliding-window loading still rides the per-row `.task` inside `row(...)`,
    /// and the per-row drag comes from there too; a tap selects/opens the row
    /// and the context menu is attached here (the old List-level menu is gone).
    /// Swipe-to-dispose, native multi-select (shift/cmd-click), the selection-
    /// aware menu, and keyboard nav are re-added in Stage B.
    @ViewBuilder
    func virtualizedList(model: MessageListViewModel, visible: [Envelope]) -> some View {
        // Spacer virtualization only when the visible rows map one-to-one onto
        // absolute folder positions: unfiltered, non-search folder mode.
        let virtualize = !model.isSearchActive && visible.count == model.envelopes.count
        let above = virtualize ? model.windowStart : 0
        let loadedBottom = model.windowStart + UInt32(model.envelopes.count)
        let below: UInt32 = virtualize && model.totalMessages > loadedBottom
            ? model.totalMessages - loadedBottom : 0
        ScrollView {
            LazyVStack(spacing: 0) {
                if let errorMessage = model.errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                if above > 0 {
                    Color.clear.frame(height: CGFloat(above) * MessageListView.rowHeight)
                }
                ForEach(visible) { envelope in
                    let selected = rowIsSelected(envelope, model: model)
                    row(
                        for: envelope,
                        model: model,
                        isSelected: selected,
                        orderedVisible: visible
                    )
                    .frame(height: MessageListView.rowHeight, alignment: .top)
                    .background(selected ? Color.accentColor.opacity(0.15) : Color.clear)
                    .contentShape(Rectangle())
                    .onTapGesture { selectRow(envelope, model: model) }
                    .contextMenu { rowContextMenu(for: envelope, model: model) }
                }
                if below > 0 {
                    Color.clear.frame(height: CGFloat(below) * MessageListView.rowHeight)
                }
            }
        }
        .overlay {
            if model.isLoading && model.envelopes.isEmpty {
                ProgressView("Fetching messages…")
            }
        }
    }

    /// Wide layouts (macOS, iPad regular width, visionOS). Stage A drives
    /// single selection through `selectedUIDs` so the reading-pane derivation
    /// below keeps working; native multi-select returns in Stage B.
    @ViewBuilder
    func wideList(model: MessageListViewModel, visible: [Envelope]) -> some View {
        virtualizedList(model: model, visible: visible)
            // Derive the reading-pane selection from the selection set: exactly
            // one selected -> show that message; zero or many -> the parent
            // shows the count placeholder. One-way, so the existing
            // `.onChange(of: selection)` cross-folder routing is unchanged.
            .onChange(of: model.selectedUIDs) { _, uids in
                if uids.count == 1 { model.selectionAnchor = uids.first }
                selection = uids.count == 1
                    ? model.envelopes.first { $0.uid == uids.first }
                    : nil
                onSelectionCountChanged(uids.count)
            }
    }

    /// Single-selection list for compact iPhone: a tap opens the reader.
    @ViewBuilder
    func compactList(model: MessageListViewModel, visible: [Envelope]) -> some View {
        virtualizedList(model: model, visible: visible)
    }

    /// Sets single selection from a tap. Wide layouts route through
    /// `selectedUIDs` (the reading pane derives from it); compact sets the
    /// navigation `selection` directly.
    func selectRow(_ envelope: Envelope, model: MessageListViewModel) {
        if isWideLayout {
            model.selectedUIDs = [envelope.uid]
        } else {
            selection = envelope
        }
    }

    /// Whether a row should render as selected. On wide layouts this is set
    /// membership (the native list draws the highlight; this only tints the
    /// unread dot); on compact it mirrors the single-selection binding.
    func rowIsSelected(_ envelope: Envelope, model: MessageListViewModel) -> Bool {
        isWideLayout ? model.selectedUIDs.contains(envelope.uid) : envelope == selection
    }

    /// The bottom bulk-action bar shows whenever a real multi-selection exists
    /// (two or more) - a single selection uses the reading pane and its own
    /// toolbar. On iPad / visionOS it also shows while the Select edit mode is
    /// active so the bar is reachable before any row is picked. Compact iPhone
    /// keeps the explicit `bulkMode` gate.
    func showsBulkActionBar(model: MessageListViewModel) -> Bool {
        guard isWideLayout else { return model.bulkMode }
        #if os(macOS)
        return model.selectedUIDs.count >= 2
        #else
        return model.selectedUIDs.count >= 2 || editMode == .active
        #endif
    }

    /// Esc clears the selection and exits any touch edit mode. Returns
    /// `.ignored` when there's nothing to clear so the key can do other things.
    func escapePressed(model: MessageListViewModel) -> KeyPress.Result {
        let hadSelection = !model.selectedUIDs.isEmpty
        #if !os(macOS)
        let wasEditing = editMode == .active
        editMode = .inactive
        #else
        let wasEditing = false
        #endif
        guard hadSelection || wasEditing else { return .ignored }
        model.selectedUIDs.removeAll()
        return .handled
    }
}

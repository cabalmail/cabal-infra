import SwiftUI
import CabalmailKit
#if canImport(AppKit)
import AppKit
#endif

// Selection plumbing for `MessageListView`: the two `List` variants (native
// multiple selection on wide/keyboard layouts, single selection on compact
// iPhone) and the helpers that derive row state and handle the keyboard
// idioms. Lives in a sibling extension so the primary view body stays under
// SwiftLint's `type_body_length` / `file_length` caps, matching the pattern
// used by `+Rows`, `+Bulk`, `+Filter`, and `+macOS`.
extension MessageListView {
    /// Virtualized message list -- index-addressed ScrollView rewrite. The
    /// `ForEach` spans the full, stable `0..<rowCount` folder index range, so
    /// scrolling never re-diffs or restructures the list (no jump) and
    /// `LazyVStack` realizes only the ~visible rows. Each slot looks up its
    /// envelope via `model.envelope(at:)` and renders a placeholder until the
    /// loaded window covers it; `ensureLoaded(around:)` (on each row's `.task`)
    /// slides/jumps the window to follow the scroll. All rows are pinned to
    /// `MessageListView.rowHeight`, so the extent is exactly `rowCount * height`
    /// -- a stable, true-to-size scrollbar with no spacer cells. A tap
    /// selects/opens; the per-row context menu and drag come from `row(...)`.
    /// Swipe-to-dispose, native multi-select, and keyboard nav are Stage B.
    ///
    /// Filtered / search mode (visible != all loaded) can't map rows onto
    /// absolute folder slots, so it falls back to a plain `ForEach(visible)`.
    @ViewBuilder
    func virtualizedList(model: MessageListViewModel, visible: [Envelope]) -> some View {
        let virtualize = !model.isSearchActive && visible.count == model.envelopes.count
        // Use the larger of the STATUS total and the loaded extent so a cache
        // hydrate (which fills `envelopes` before `refresh` sets the total)
        // still shows its rows.
        let rowCount = max(Int(model.totalMessages), Int(model.windowStart) + model.envelopes.count)
        ScrollView {
            LazyVStack(spacing: 0) {
                if let errorMessage = model.errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                if virtualize {
                    ForEach(0..<rowCount, id: \.self) { index in
                        indexedRow(index, model: model, visible: visible)
                    }
                } else {
                    ForEach(visible) { envelope in
                        messageRow(envelope, model: model, visible: visible)
                    }
                }
            }
        }
        .overlay {
            if model.isLoading && model.envelopes.isEmpty {
                ProgressView("Fetching messages…")
            }
        }
    }

    /// One virtualized slot: the real row when its envelope is loaded, a
    /// placeholder otherwise. Either way its `.task` calls `ensureLoaded` so
    /// scrolling (including a scrollbar jump onto placeholders) pulls the
    /// window to cover this index.
    @ViewBuilder
    private func indexedRow(_ index: Int, model: MessageListViewModel, visible: [Envelope]) -> some View {
        Group {
            if let envelope = model.envelope(at: index) {
                messageRow(envelope, model: model, visible: visible)
            } else {
                placeholderRow()
            }
        }
        .task { model.ensureLoaded(around: index) }
    }

    /// A loaded message row at the fixed row height. The normal row wraps in
    /// `SwipeActionRow` for swipe-to-dispose (trailing) / toggle-read
    /// (leading) on touch -- `.swipeActions` is `List`-only, so the
    /// virtualized `ScrollView` rows hand-roll it (see `SwipeActionRow.swift`).
    /// `SwipeActionRow` also owns the row's height, background, and tap-to-
    /// select (a tap closes an open swipe instead of selecting). Compact
    /// edit mode (`bulkMode`) bypasses swipe: the row is a selection-toggle
    /// button there, and swipe in a multi-select edit mode would fight it
    /// (matching Mail, which disables swipe while editing). Shared by the
    /// virtualized and filtered paths.
    @ViewBuilder
    private func messageRow(_ envelope: Envelope, model: MessageListViewModel, visible: [Envelope]) -> some View {
        let selected = rowIsSelected(envelope, model: model)
        let background = selected ? Color.accentColor.opacity(0.15) : Color.clear
        Group {
            if model.bulkMode {
                row(for: envelope, model: model, isSelected: selected, orderedVisible: visible)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: MessageListView.rowHeight, alignment: .top)
                    .background(background)
            } else {
                // `draggableRow` (drag-to-folder) wraps OUTSIDE `SwipeActionRow`
                // so the drag sits on the row container, not inside the embedded
                // List that owns the swipe -- a `.draggable` within that List row
                // is swallowed on macOS and never lifts.
                draggableRow(for: envelope, model: model) {
                    SwipeActionRow(
                        height: MessageListView.rowHeight,
                        rowBackground: background,
                        leading: toggleReadSwipe(for: envelope, model: model),
                        trailing: disposeSwipe(for: envelope, model: model),
                        onSelect: { selectRow(envelope, model: model, ordered: visible) },
                        content: {
                            row(for: envelope, model: model, isSelected: selected, orderedVisible: visible)
                        }
                    )
                }
            }
        }
        .contextMenu { rowContextMenu(for: envelope, model: model) }
    }

    /// Skeleton row shown for an index whose envelope isn't loaded yet. Same
    /// fixed height as a real row so the scroll extent and every row's
    /// absolute position are exact while the window catches up.
    private func placeholderRow() -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle().fill(.quaternary).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: 3).fill(.quaternary).frame(width: 150, height: 11)
                RoundedRectangle(cornerRadius: 3).fill(.quaternary).frame(width: 230, height: 11)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .frame(height: MessageListView.rowHeight, alignment: .top)
        .redacted(reason: .placeholder)
        .accessibilityHidden(true)
    }

    /// Wide layouts (macOS, iPad regular width, visionOS). Selection lives in
    /// `selectedUIDs`: a plain click selects one, and on macOS command/shift
    /// clicks build a multi-selection (see `selectRow`). The reading-pane
    /// derivation below shows the single selected message, or hands the parent
    /// a count placeholder for zero / many.
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

    /// Sets selection from a tap. Compact iPhone opens the reader directly.
    /// Wide layouts route through `selectedUIDs` (the reading pane derives
    /// from it). On macOS the tap is modifier-aware -- command toggles the
    /// row, shift extends the range from the anchor, a plain click replaces
    /// the selection -- read from `NSEvent.modifierFlags` at click time, the
    /// AppKit equivalent of the iOS `ModifierClickGesture`. iPad-wide takes a
    /// plain click as single-select here; its hardware-keyboard shift/command
    /// clicks come through `ModifierClickGesture` in `wideRow` instead.
    func selectRow(_ envelope: Envelope, model: MessageListViewModel, ordered: [Envelope]) {
        guard isWideLayout else { selection = envelope; return }
        #if os(macOS)
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            applyToggleSelection(envelope, model: model)
            return
        }
        if flags.contains(.shift) {
            applyRangeSelection(to: envelope, model: model, ordered: ordered)
            return
        }
        #endif
        model.selectedUIDs = [envelope.uid]
        model.selectionAnchor = envelope.uid
    }

    /// Shift-click range selection over `ordered` (the visible rows in display
    /// order), from the current anchor to `target`, inclusive. Falls back to
    /// selecting just `target` if the anchor can't be located. Shared by the
    /// macOS modifier-click path (`selectRow`) and the iOS `ModifierClickGesture`
    /// (`wideRow`); the original anchor is kept so a following shift-click
    /// re-pivots from it.
    func applyRangeSelection(to target: Envelope, model: MessageListViewModel, ordered: [Envelope]) {
        let anchorUID = model.selectionAnchor ?? model.selectedUIDs.first
        guard let anchorUID,
              let anchorIndex = ordered.firstIndex(where: { $0.uid == anchorUID }),
              let targetIndex = ordered.firstIndex(where: { $0.uid == target.uid }) else {
            model.selectedUIDs = [target.uid]
            model.selectionAnchor = target.uid
            return
        }
        let lower = min(anchorIndex, targetIndex)
        let upper = max(anchorIndex, targetIndex)
        model.selectedUIDs = Set(ordered[lower...upper].map(\.uid))
    }

    /// Command/control-click: flip the row's membership and make it the new
    /// anchor for any following shift-click.
    func applyToggleSelection(_ envelope: Envelope, model: MessageListViewModel) {
        model.toggleSelection(envelope)
        model.selectionAnchor = envelope.uid
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

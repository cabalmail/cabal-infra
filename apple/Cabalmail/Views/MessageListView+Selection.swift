import SwiftUI
import CabalmailKit

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
                SwipeActionRow(
                    height: MessageListView.rowHeight,
                    rowBackground: background,
                    leading: toggleReadSwipe(for: envelope, model: model),
                    trailing: disposeSwipe(for: envelope, model: model),
                    onSelect: { selectRow(envelope, model: model) },
                    content: {
                        row(for: envelope, model: model, isSelected: selected, orderedVisible: visible)
                    }
                )
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

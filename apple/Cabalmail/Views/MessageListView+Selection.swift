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
    /// `rowHeight`, so the extent is exactly `rowCount * height`
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
        ScrollViewReader { proxy in
            keyboardScoped(
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
                },
                model: model, visible: visible, proxy: proxy
            )
        }
        .overlay {
            if model.isLoading && model.envelopes.isEmpty {
                ProgressView("Fetching messages…")
            }
        }
    }

    /// Focus-scopes the list and installs its hardware-keyboard handlers. The
    /// ScrollView is the focus target, so these keys fire only while the list
    /// holds focus -- when the search field has focus instead, they stay with
    /// it (Cmd-A selects its text, Esc cancels search). The focus ring is
    /// suppressed; the row highlight already marks the active row. Pulled out of
    /// `virtualizedList` to stay under SwiftLint's function-body cap.
    @ViewBuilder
    private func keyboardScoped(
        _ content: some View,
        model: MessageListViewModel,
        visible: [Envelope],
        proxy: ScrollViewProxy
    ) -> some View {
        let virtualize = !model.isSearchActive && visible.count == model.envelopes.count
        let rowCount = max(Int(model.totalMessages), Int(model.windowStart) + model.envelopes.count)
        content
            .focusable(isWideLayout)
            .focusEffectDisabled()
            .focused($listFocused)
            .onKeyPress(keys: [.upArrow, .downArrow]) { press in
                moveSelection(
                    by: press.key == .downArrow ? 1 : -1,
                    extend: press.modifiers.contains(.shift),
                    model: model, visible: visible, proxy: proxy
                )
            }
            .onKeyPress(.escape) { escapePressed(model: model) }
            .onKeyPress(keys: ["a"]) { press in
                guard press.modifiers.contains(.command) else { return .ignored }
                model.selectAllVisible()
                return .handled
            }
            // Home / End jump the list to the top / bottom of the folder,
            // leaving the selection where it is (a scroll, not a move).
            .onKeyPress(keys: [.home, .end]) { press in
                homeEndScroll(toEnd: press.key == .end, model: model, visible: visible, proxy: proxy)
            }
            .onKeyPress(keys: [.pageUp, .pageDown]) { press in
                pageScroll(down: press.key == .pageDown, model: model,
                           proxy: proxy, rowCount: rowCount, virtualize: virtualize)
            }
    }

    /// PgUp / PgDown scroll the list by ~one visible page, leaving the
    /// selection where it is. We scroll so the row at the far edge of the
    /// current view lands at the near edge -- one row of overlap for context --
    /// derived from the index range the rows report via onAppear/onDisappear.
    /// The page FETCH, if we land on unloaded rows, is debounced
    /// (`scheduleEnsureLoaded`) so a fast run of presses loads only where it
    /// settles. Folder mode only; the search/filter list isn't index-addressed.
    private func pageScroll(
        down: Bool,
        model: MessageListViewModel,
        proxy: ScrollViewProxy,
        rowCount: Int,
        virtualize: Bool
    ) -> KeyPress.Result {
        guard isWideLayout, virtualize, rowCount > 0,
              let first = model.firstVisibleRow, let last = model.lastVisibleRow
        else { return .ignored }
        withAnimation(.easeOut(duration: 0.12)) {
            proxy.scrollTo(down ? last : first, anchor: down ? .top : .bottom)
        }
        // The post-scroll row appears re-arm the settle backstop, which loads
        // the window at the new visible center once it stops.
        model.scheduleEnsureLoaded()
        return .handled
    }

    /// Home / End jump the list to the top / bottom of the folder, leaving the
    /// selection where it is. The destination window load is driven EXPLICITLY
    /// here, not left to the landing rows' `.task`: during the animated jump
    /// the rows swept through fire `ensureLoaded` first and claim the single-
    /// flight `isLoadingWindow` for a mid-list index, so the destination rows'
    /// own `ensureLoaded` bails on that gate and the window never reaches them
    /// -- the bottom stays on placeholders forever, no matter how long you
    /// wait. Claiming the load here, for the real target and before any row
    /// realizes, makes those interlopers bail instead. End is clamped to the
    /// last STATUS-backed message: `rowCount` can run ahead of the folder total
    /// (a stale cache window, or `windowStart + count` transiently past
    /// `totalMessages`), and a row past `total - 1` can never be filled by a
    /// positional fetch, so scrolling there would strand a permanent
    /// placeholder. Filtered / search rows are id-addressed, so scroll to the
    /// first / last loaded envelope instead.
    private func homeEndScroll(
        toEnd: Bool,
        model: MessageListViewModel,
        visible: [Envelope],
        proxy: ScrollViewProxy
    ) -> KeyPress.Result {
        guard isWideLayout else { return .ignored }
        let virtualize = !model.isSearchActive && visible.count == model.envelopes.count
        let rowCount = max(Int(model.totalMessages), Int(model.windowStart) + model.envelopes.count)
        let anchor: UnitPoint = toEnd ? .bottom : .top
        if virtualize, rowCount > 0 {
            let total = Int(model.totalMessages)
            let target = toEnd ? (total > 0 ? min(rowCount - 1, total - 1) : rowCount - 1) : 0
            model.ensureLoaded(around: target)
            withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(target, anchor: anchor) }
        } else if let edge = toEnd ? visible.last : visible.first {
            withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(edge.id, anchor: anchor) }
        }
        return .handled
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
        // Track the rendered index range (main-actor callbacks) so PgUp/PgDown
        // can page by the actual visible extent. Cheap, @ObservationIgnored.
        .onAppear { model.noteRowVisible(index) }
        .onDisappear { model.noteRowHidden(index) }
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
                    .frame(height: rowHeight, alignment: .center)
                    .background(background)
            } else {
                // `draggableRow` (drag-to-folder) wraps OUTSIDE the swipe row
                // so the drag sits on the row container, not inside the swipe
                // mechanism -- a `.draggable` within the embedded List the
                // macOS path uses is swallowed and never lifts.
                draggableRow(for: envelope, model: model) {
                    swipeRow(
                        for: envelope, model: model,
                        background: background, visible: visible, selected: selected
                    )
                }
            }
        }
        .contextMenu {
            // Right-clicking a row that's part of a multi-selection acts on the
            // whole selection (Finder / Mail semantics); otherwise it's the
            // single right-clicked row.
            if model.selectedUIDs.count > 1, model.selectedUIDs.contains(envelope.uid) {
                selectionContextMenu(for: model.selectedUIDs, model: model)
            } else {
                rowContextMenu(for: envelope, model: model)
            }
        }
        .overlay(alignment: .bottom) { rowSeparator() }
    }

    /// The swipe-actions wrapper for a loaded row. Touch platforms (iOS /
    /// iPadOS / visionOS) use the hand-rolled `SwipeRow` -- a `ZStack` +
    /// `DragGesture`, no nested scroll view. The per-row embedded `List` that
    /// borrowing native `.swipeActions` requires made a background scene-update
    /// relayout exceed the 10-second watchdog (0x8BADF00D), killing the app a
    /// second or two after an archive-then-background even on a folder of fewer
    /// than 30 messages. macOS keeps the native `.swipeActions` via
    /// `SwipeActionRow`: there the swipe is a two-finger trackpad scroll gesture
    /// a `DragGesture` can't read, and the Mac has no scene-update watchdog.
    @ViewBuilder
    private func swipeRow(
        for envelope: Envelope,
        model: MessageListViewModel,
        background: Color,
        visible: [Envelope],
        selected: Bool
    ) -> some View {
        #if os(macOS)
        SwipeActionRow(
            height: rowHeight,
            rowBackground: background,
            leading: toggleReadSwipe(for: envelope, model: model),
            trailing: disposeSwipe(for: envelope, model: model),
            onSelect: { selectRow(envelope, model: model, ordered: visible) },
            content: {
                row(for: envelope, model: model, isSelected: selected, orderedVisible: visible)
            }
        )
        #else
        SwipeRow(
            height: rowHeight,
            rowBackground: background,
            leading: toggleReadSwipe(for: envelope, model: model),
            trailing: disposeSwipe(for: envelope, model: model),
            onSelect: { selectRow(envelope, model: model, ordered: visible) },
            resetKey: envelope.uid,
            content: {
                row(for: envelope, model: model, isSelected: selected, orderedVisible: visible)
            }
        )
        #endif
    }

    /// Thin hairline between rows. Drawn as a bottom `.overlay` (not a stack
    /// member) so it adds NO height: index-addressed virtualization pins every
    /// row to `rowHeight` and the scroll extent is
    /// `rowCount * rowHeight`, so a row that grew by a divider's height would
    /// drift the placeholder rows out of alignment with their slots (see
    /// `virtualizedList`). `Divider` carries the platform's system separator
    /// color and thickness, for a thin, unobtrusive line; `allowsHitTesting`
    /// is off so the line never steals the row's tap / swipe targets.
    private func rowSeparator() -> some View {
        Divider().allowsHitTesting(false)
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
        .frame(height: rowHeight, alignment: .center)
        .redacted(reason: .placeholder)
        .accessibilityHidden(true)
        .overlay(alignment: .bottom) { rowSeparator() }
    }

    /// Wide layouts (macOS, iPad regular width, visionOS). Selection lives in
    /// `selectedUIDs`: a plain click selects one, and on macOS command/shift
    /// clicks build a multi-selection (see `selectRow`). The reading-pane
    /// derivation below shows the single selected message, or hands the parent
    /// a count placeholder for zero / many.
    @ViewBuilder
    func wideList(model: MessageListViewModel, visible: [Envelope]) -> some View {
        virtualizedList(model: model, visible: visible)
            .background {
                // Window-scoped Cmd+Delete on the selection. A hidden button
                // (not a menu item) so the chord fires regardless of which pane
                // has focus without going app-wide -- a menu equivalent would
                // also trigger from the compose window and steal the text
                // system's delete-to-line-start. ONLY installed while 2+ rows
                // are selected: a single selection is the reading pane's
                // territory (its dispose button owns Cmd+Delete there), and
                // installing both equivalents in one window at once leaves
                // AppKit to pick a winner -- which is why an always-on button
                // silently did nothing.
                if model.selectedUIDs.count > 1 {
                    Button("") { disposeSelection(model: model) }
                        .keyboardShortcut(.delete, modifiers: .command)
                        .opacity(0)
                        .accessibilityHidden(true)
                }
            }
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
        // Clicking a row focuses the list so keyboard nav takes over from here.
        listFocused = true
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
        model.selectionCursor = envelope.uid
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
            model.selectionCursor = target.uid
            return
        }
        let lower = min(anchorIndex, targetIndex)
        let upper = max(anchorIndex, targetIndex)
        model.selectedUIDs = Set(ordered[lower...upper].map(\.uid))
        // Cursor follows the shift-clicked end so a subsequent shift-arrow
        // grows the range from here, not from the anchor.
        model.selectionCursor = target.uid
    }

    /// Command/control-click: flip the row's membership and make it the new
    /// anchor for any following shift-click.
    func applyToggleSelection(_ envelope: Envelope, model: MessageListViewModel) {
        model.toggleSelection(envelope)
        model.selectionAnchor = envelope.uid
        model.selectionCursor = envelope.uid
    }

    /// Up/Down arrow navigation, and Shift+Up/Down range extension. A plain
    /// arrow replaces the selection with the previous / next visible row; a
    /// shift-arrow grows or shrinks the range between the fixed anchor and the
    /// moving cursor. Either way the new cursor scrolls into view. Wide layouts
    /// only; `.ignored` when there's nothing to move so the key falls through.
    /// With no current selection, Down lands on the first row, Up the last.
    func moveSelection(
        by delta: Int,
        extend: Bool,
        model: MessageListViewModel,
        visible: [Envelope],
        proxy: ScrollViewProxy
    ) -> KeyPress.Result {
        guard isWideLayout, !visible.isEmpty else { return .ignored }
        let virtualize = !model.isSearchActive && visible.count == model.envelopes.count
        // Move from the current cursor (the moving end), falling back to the
        // anchor / first selected row when keyboard nav hasn't started yet.
        let cursorUID = model.selectionCursor ?? model.selectionAnchor ?? model.selectedUIDs.first
        let cursorIdx = cursorUID.flatMap { uid in visible.firstIndex { $0.uid == uid } }
        let next: Int
        if let cursorIdx {
            next = min(max(cursorIdx + delta, 0), visible.count - 1)
        } else {
            next = delta > 0 ? 0 : visible.count - 1
        }
        let target = visible[next]
        if extend {
            // Anchor stays put; the range spans anchor...cursor inclusive.
            let anchorUID = model.selectionAnchor ?? cursorUID ?? target.uid
            let anchorIdx = visible.firstIndex { $0.uid == anchorUID } ?? next
            model.selectedUIDs = Set(visible[min(anchorIdx, next)...max(anchorIdx, next)].map(\.uid))
            model.selectionCursor = target.uid
        } else {
            model.selectedUIDs = [target.uid]
            model.selectionAnchor = target.uid
            model.selectionCursor = target.uid
        }
        // The virtualized `ForEach` is keyed by absolute folder index (Int);
        // the filtered fallback by envelope id. Scroll to whichever the active
        // `ForEach` uses (in virtualize mode `visible` == `envelopes`, so the
        // absolute index is `windowStart + next`).
        withAnimation(.easeOut(duration: 0.12)) {
            if virtualize {
                proxy.scrollTo(Int(model.windowStart) + next, anchor: .center)
            } else {
                proxy.scrollTo(target.id, anchor: .center)
            }
        }
        return .handled
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
        model.selectionAnchor = nil
        model.selectionCursor = nil
        return .handled
    }
}

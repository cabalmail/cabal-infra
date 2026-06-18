import SwiftUI
import CabalmailKit

// Selection plumbing for `MessageListView`: the two `List` variants (native
// multiple selection on wide/keyboard layouts, single selection on compact
// iPhone) and the helpers that derive row state and handle the keyboard
// idioms. Lives in a sibling extension so the primary view body stays under
// SwiftLint's `type_body_length` / `file_length` caps, matching the pattern
// used by `+Rows`, `+Bulk`, `+Filter`, and `+macOS`.
extension MessageListView {
    /// Native multiple-selection list for macOS, iPad regular width, and
    /// visionOS. A plain click selects and opens one message, shift-click
    /// extends a contiguous range, and command-click toggles an individual
    /// row - all handled by SwiftUI's `Set`-bound selection. `selectedUIDs`
    /// is the source of truth; the reading-pane `selection` is derived from it
    /// in `content(for:)`'s `.onChange(of: selectedUIDs)`. iPad / visionOS also
    /// bind EditMode so touch users can multi-select via the Select button.
    @ViewBuilder
    func wideList(model: MessageListViewModel, visible: [Envelope]) -> some View {
        @Bindable var model = model
        List(selection: $model.selectedUIDs) {
            listContent(model: model, visible: visible)
        }
        #if !os(macOS)
        .environment(\.editMode, $editMode)
        #endif
        // Right-click / long-press menu at the List level so SwiftUI
        // resolves the target set natively: the whole selection when the
        // click lands on a selected row, just the clicked row when it
        // doesn't. Replaces the per-row `.contextMenu`, which only ever
        // saw the row under the pointer.
        .contextMenu(forSelectionType: UInt32.self) { uids in
            selectionContextMenu(for: uids, model: model)
        }
        // Cmd-A select-all and Esc clear, scoped to the list's focus so they
        // never steal those keys from the search field.
        .onKeyPress(.escape) { escapePressed(model: model) }
        .onKeyPress(keys: ["a"], phases: .down) { keyPress in
            guard keyPress.modifiers.contains(.command) else { return .ignored }
            model.selectAllVisible()
            return .handled
        }
        // Cmd+Delete for a multi-selection. Window-scoped (a key equivalent
        // on an invisible button), NOT focus-scoped like Esc / Cmd-A above:
        // the user can't easily tell whether the list or the reading pane
        // holds focus, so the dispose chord must behave the same either way
        // - exactly how the detail toolbar's own Cmd+Delete equivalent
        // already works. Only installed while two or more rows are selected;
        // a single selection is the reading pane's territory (its dispose
        // button owns Cmd+Delete there and additionally advances to the next
        // unread), and installing both at once would leave AppKit to pick a
        // winner between two identical equivalents in one window.
        .background {
            if model.selectedUIDs.count > 1 {
                Button("") { disposeSelection(model: model) }
                    .keyboardShortcut(.delete, modifiers: .command)
                    .opacity(0)
                    .accessibilityHidden(true)
            }
        }
        // Derive the reading-pane selection from the multi-select set: exactly
        // one selected -> show that message; zero or many -> the parent shows
        // "No message selected" / "N messages selected" via the reported count.
        // One-way, so the existing `.onChange(of: selection)` cross-folder
        // routing keeps working unchanged.
        .onChange(of: model.selectedUIDs) { _, uids in
            // A fresh single selection (plain click) becomes the anchor for a
            // following shift-click range; range/toggle clicks set the anchor
            // themselves. Harmless on macOS, which uses its own native anchor.
            if uids.count == 1 { model.selectionAnchor = uids.first }
            selection = uids.count == 1
                ? model.envelopes.first { $0.uid == uids.first }
                : nil
            onSelectionCountChanged(uids.count)
        }
    }

    /// Single-selection list for compact iPhone: a tap opens the reader, and
    /// the touch "Select" edit mode (driven by `bulkMode`) handles multi-
    /// select. No keyboard, so no modifier-click idioms here.
    @ViewBuilder
    func compactList(model: MessageListViewModel, visible: [Envelope]) -> some View {
        List(selection: $selection) {
            listContent(model: model, visible: visible)
        }
    }

    /// List rows shared by both variants. Factored out so each `List` can carry
    /// its own selection-binding generic without duplicating the row content.
    @ViewBuilder
    func listContent(model: MessageListViewModel, visible: [Envelope]) -> some View {
        if let errorMessage = model.errorMessage {
            Label(errorMessage, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
        }
        if model.isLoading && model.envelopes.isEmpty {
            ProgressView("Fetching messages…")
        }
        // Spacer virtualization: when showing the unfiltered folder, reserve
        // the off-window rows as fixed-height blank cells so the scroll extent
        // (and the scrollbar) reflect the whole folder and the viewport never
        // jumps as the window trims/reloads -- each loaded row keeps its
        // absolute position. Disabled under a filter or search, where the
        // visible rows don't map one-to-one onto absolute folder positions.
        let virtualize = !model.isSearchActive && visible.count == model.envelopes.count
        if virtualize, model.windowStart > 0 {
            spacerRow(rows: model.windowStart)
        }
        ForEach(visible) { envelope in
            row(
                for: envelope,
                model: model,
                isSelected: rowIsSelected(envelope, model: model),
                orderedVisible: visible
            )
            .frame(height: MessageListView.rowHeight, alignment: .top)
            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
            .listRowSeparator(.hidden)
        }
        if virtualize {
            let loadedBottom = model.windowStart + UInt32(model.envelopes.count)
            if model.totalMessages > loadedBottom {
                spacerRow(rows: model.totalMessages - loadedBottom)
            }
        } else if model.isLoadingMore {
            ProgressView()
                .frame(maxWidth: .infinity)
        }
    }

    /// A single blank list cell standing in for `rows` unloaded messages, sized
    /// to their exact height (`rows * rowHeight`). Carries no separator, no
    /// insets, and is unselectable so List selection / keyboard navigation skip
    /// it. The pair of these (above and below the window) is what makes the
    /// scroll extent match the full folder without rendering every row.
    private func spacerRow(rows: UInt32) -> some View {
        Color.clear
            .frame(height: CGFloat(rows) * MessageListView.rowHeight)
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .selectionDisabled()
            .accessibilityHidden(true)
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

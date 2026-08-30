import SwiftUI
import CabalmailKit

// The reader toolbar's flag control and its custom-flag menu
// (rules-composition plan, Phase 4). A sibling of
// `MessageDetailView+SeenOptions.swift` — same split-control pattern,
// same file-length reasoning.

extension MessageDetailView {
    /// The toolbar's flag control: the face still toggles `\Flagged` (the
    /// primary action, same as before Phase 4), and the menu offers one
    /// checkmark toggle per palette flag. macOS renders a split button;
    /// touch platforms keep the plain toggle with the menu on
    /// touch-and-hold. While the palette is empty the control stays the
    /// plain button it always was — no dead menu, no footprint change.
    @ViewBuilder
    var flagButton: some View {
        if let model {
            let rows = menuRows(model: model)
            if rows.isEmpty {
                Button {
                    Task { await model.toggleFlagged() }
                } label: {
                    flagToolbarLabel(isFlagged: model.isFlagged)
                }
                // Cmd+Shift+L rides `readerChordHosts`, not this button — an
                // equivalent on a toolbar item dies with the item when the
                // toolbar overflows (#1047).
                .accessibilityIdentifier("reader.toggleFlag")
            } else {
                Menu {
                    keywordOptionItems(rows: rows, model: model)
                } label: {
                    flagToolbarLabel(isFlagged: model.isFlagged)
                } primaryAction: {
                    Task { await model.toggleFlagged() }
                }
                .menuIndicator(optionMenuIndicator)
                .accessibilityIdentifier("reader.toggleFlag")
                // macOS keeps the AppKit menu it built the first time this
                // `Menu` was opened, checkmarks and titles included, so the
                // identity carries what the rows draw (#1329).
                .id(FlagMenuPolicy.identity(rows))
            }
        }
    }

    @ViewBuilder
    private func flagToolbarLabel(isFlagged: Bool) -> some View {
        Label(
            isFlagged ? "Unflag" : "Flag",
            systemImage: isFlagged ? "flag.slash" : "flag"
        )
    }

    /// The rows the menu offers, read here so the enclosing body observes
    /// the tag set — the identity below is derived from the same values.
    func menuRows(model: MessageDetailViewModel) -> [FlagMenuRow] {
        FlagMenuPolicy.rows(
            palette: preferences.flagPalette,
            taggedSlots: model.keywordSlots
        )
    }

    /// One checkmark toggle per row. `isOn` reads the row rather than the
    /// model so the drawn state and the menu's identity can never disagree.
    @ViewBuilder
    func keywordOptionItems(
        rows: [FlagMenuRow],
        model: MessageDetailViewModel
    ) -> some View {
        ForEach(rows) { row in
            Toggle(isOn: Binding(
                get: { row.isOn },
                set: { _ in
                    Task { await model.toggleKeyword(row.slot) }
                }
            )) {
                Text(row.label)
            }
        }
    }
}

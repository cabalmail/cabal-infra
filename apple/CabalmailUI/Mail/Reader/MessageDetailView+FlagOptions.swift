import SwiftUI
import CabalmailKit

// The reader toolbar's flag control and its flag menu (rules-composition
// plan, Phase 4; unified-flags plan, Phase 3). A sibling of
// `MessageDetailView+SeenOptions.swift` — same split-control pattern,
// same file-length reasoning.

extension MessageDetailView {
    /// The toolbar's flag control: the face toggles the default flag (the
    /// primary action, named for the flag by `FlagToggle`), and the menu
    /// offers one checkmark toggle per palette flag. macOS renders a split
    /// button; touch platforms keep the plain toggle with the menu on
    /// touch-and-hold. While the default flag is the only one offered the
    /// control stays the plain button it always was — no dead menu, no
    /// footprint change. With no default flag the face is dimmed, and the
    /// menu, if the message carries a flag to clear, still opens.
    @ViewBuilder
    var flagButton: some View {
        if let model {
            let rows = menuRows(model: model)
            if rows.isEmpty {
                Button {
                    Task { await model.toggleDefaultFlag() }
                } label: {
                    flagToolbarLabel(model: model)
                }
                .disabled(model.defaultFlag == nil)
                // Cmd+Shift+L rides `readerChordHosts`, not this button — an
                // equivalent on a toolbar item dies with the item when the
                // toolbar overflows (#1047).
                .accessibilityIdentifier("reader.toggleFlag")
            } else {
                Menu {
                    flagOptionItems(rows: rows, model: model)
                } label: {
                    flagToolbarLabel(model: model)
                } primaryAction: {
                    Task { await model.toggleDefaultFlag() }
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

    #if os(iOS)
    /// Overflow-menu rows standing in for the flag control where the compact
    /// navigation bar leaves it off (`ReaderToolbarLayout.topBarDemotedToOverflow`):
    /// the plain toggle, then the palette's flags as a submenu in place of
    /// the control's touch-and-hold menu. Shown only while the bar lacks the
    /// control, so the accessibility identifier stays unique.
    @ViewBuilder
    var flagMenuItems: some View {
        if let model {
            Button {
                Task { await model.toggleDefaultFlag() }
            } label: {
                flagToolbarLabel(model: model)
            }
            .disabled(model.defaultFlag == nil)
            .accessibilityIdentifier("reader.toggleFlag")
            let rows = menuRows(model: model)
            if !rows.isEmpty {
                Menu {
                    flagOptionItems(rows: rows, model: model)
                } label: {
                    Label("Flags", systemImage: "tag")
                }
            }
        }
    }
    #endif

    /// The face of the control: what a press does to the default flag.
    /// With none, the classic "Flag" face, dimmed by its caller.
    private func flagToolbarLabel(model: MessageDetailViewModel) -> some View {
        let face = model.defaultFlag?.face(isSet: model.isDefaultFlagSet)
            ?? ReaderToggleFace.flag(isFlagged: false)
        return face.label
    }

    /// The rows the menu offers, read here so the enclosing body observes
    /// the flags — the identity below is derived from the same values.
    func menuRows(model: MessageDetailViewModel) -> [FlagMenuRow] {
        FlagMenuPolicy.rows(
            palette: preferences.flagPalette,
            taggedSlots: Set(FlagPalette.slots(in: model.shownFlags, palette: preferences.flagPalette))
        )
    }

    /// One checkmark toggle per row. `isOn` reads the row rather than the
    /// model so the drawn state and the menu's identity can never disagree.
    @ViewBuilder
    func flagOptionItems(
        rows: [FlagMenuRow],
        model: MessageDetailViewModel
    ) -> some View {
        ForEach(rows) { row in
            Toggle(isOn: Binding(
                get: { row.isOn },
                set: { _ in
                    Task { await model.toggle(Flag(wireValue: row.slot)) }
                }
            )) {
                Text(row.label)
            }
        }
    }
}

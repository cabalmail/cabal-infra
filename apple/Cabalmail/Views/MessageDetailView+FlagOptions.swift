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
            if menuSlots(model: model).isEmpty {
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
                    keywordOptionItems(model: model)
                } label: {
                    flagToolbarLabel(isFlagged: model.isFlagged)
                } primaryAction: {
                    Task { await model.toggleFlagged() }
                }
                .menuIndicator(optionMenuIndicator)
                .accessibilityIdentifier("reader.toggleFlag")
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

    /// The slots the menu offers: every enabled palette entry, plus any
    /// slot the message is already tagged with whose entry is disabled or
    /// deleted — those still need an untag affordance (the palette
    /// editor's delete confirmation promises tags stay removable).
    private func menuSlots(model: MessageDetailViewModel) -> [String] {
        let offered = preferences.flagPalette.filter(\.enabled).map(\.slot)
        let stray = FlagPalette.slots
            .filter { model.keywordSlots.contains($0) && !offered.contains($0) }
        return offered + stray
    }

    /// One checkmark toggle per slot, labelled from the palette when the
    /// entry exists (disabled entries keep their label) and by slot id for
    /// a deleted slot's surviving tag.
    @ViewBuilder
    func keywordOptionItems(model: MessageDetailViewModel) -> some View {
        ForEach(menuSlots(model: model), id: \.self) { slot in
            Toggle(isOn: Binding(
                get: { model.keywordSlots.contains(slot) },
                set: { _ in
                    Task { await model.toggleKeyword(slot) }
                }
            )) {
                Text(preferences.flagPalette.first { $0.slot == slot }?.label ?? slot)
            }
        }
    }
}

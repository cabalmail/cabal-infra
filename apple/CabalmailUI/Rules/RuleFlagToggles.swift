import SwiftUI
import CabalmailKit

/// The flags a rule sets, as one switch per flag in Settings > Flags and in
/// its order (unified-flags plan, decision 7). Shared by the mail rule
/// editor and the feed rule editor, whose rules carry the same two fields:
/// the built-in flag's switch is the rule's `flag`, and every other one a
/// slot in its `flags`.
///
/// A slot the rule already sets whose flag was deleted is listed too, after
/// the others and labelled by its slot id. The rule is skipped while such a
/// slot remains (the mail compiler's `flag_not_in_palette`, and the same
/// check in the feed fetcher), so the stray switch is how it is cleared.
struct RuleFlagToggles: View {
    @Binding var flag: Bool
    @Binding var flags: [String]
    /// Read from the environment like `FlagPaletteSettingsView`: the rules
    /// view models deliberately know nothing about preferences.
    @Environment(Preferences.self) private var preferences

    /// The palette as Settings > Flags shows it, the built-in flag's entry
    /// included.
    private var palette: [FlagPaletteEntry] { FlagPalette.effective(preferences.flagPalette) }

    var body: some View {
        ForEach(Self.pickerSlots(palette: palette, flags: flags), id: \.self) { slot in
            let entry = palette.first { $0.slot == slot }
            Toggle(isOn: slot == FlagPalette.systemSlot ? $flag : slotBinding(slot)) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(FlagPaletteColor.color(for: entry?.color ?? ""))
                        .frame(width: 10, height: 10)
                    Text(entry?.label ?? slot)
                }
            }
        }
    }

    /// The palette's slots, the built-in flag's among them, then the slots
    /// of deleted flags the rule still sets.
    nonisolated static func pickerSlots(palette: [FlagPaletteEntry], flags: [String]) -> [String] {
        palette.map(\.slot) + straySlots(palette: palette, flags: flags)
    }

    /// The slots the rule sets whose flag is no longer in the palette.
    nonisolated static func straySlots(palette: [FlagPaletteEntry], flags: [String]) -> [String] {
        let offered = palette.map(\.slot)
        return FlagPalette.slots.filter { flags.contains($0) && !offered.contains($0) }
    }

    private func slotBinding(_ slot: String) -> Binding<Bool> {
        Binding(
            get: { flags.contains(slot) },
            set: { isOn in
                if isOn {
                    if !flags.contains(slot) { flags.append(slot) }
                } else {
                    flags.removeAll { $0 == slot }
                }
            }
        )
    }
}

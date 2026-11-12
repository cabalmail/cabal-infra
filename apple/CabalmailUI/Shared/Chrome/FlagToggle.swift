import SwiftUI
import CabalmailKit

/// The flag a one-press control sets and clears, and the words and color
/// it does it in: the swipe action, the list and reader shortcuts, the
/// first item of the row and selection menus, the bulk bar's button and
/// the reader's flag button.
///
/// Mail's controls and the feed's act on the palette's default flag, the
/// first entry of Settings > Flags (`defaultFlag(in:)`). The Flagged
/// filters name the built-in flag, whatever its position
/// (`systemFlag(in:)`): a plain tap on the pill filters on that one.
///
/// There is always one of each: the list always holds the built-in flag,
/// and no flag can be switched off.
struct FlagToggle: Equatable {
    let slot: String
    let label: String
    let color: String

    init(_ entry: FlagPaletteEntry) {
        slot = entry.slot
        label = entry.label
        color = entry.color
    }

    /// The flag the one-press controls toggle, on a message and on a feed
    /// item: the first entry of the effective palette.
    static func defaultFlag(in stored: [FlagPaletteEntry]) -> FlagToggle {
        FlagToggle(FlagPalette.defaultEntry(in: stored))
    }

    /// The built-in flag's entry, for the Flagged filters.
    static func systemFlag(in stored: [FlagPaletteEntry]) -> FlagToggle {
        FlagToggle(
            FlagPalette.effective(stored).first { $0.slot == FlagPalette.systemSlot }
                ?? FlagPalette.defaultSystemEntry
        )
    }

    /// The built-in flag's name as a state rather than an action, for the
    /// Flagged filter pills and the search sheet's toggle: its entry's
    /// label.
    static func systemFlagName(in stored: [FlagPaletteEntry]) -> String {
        systemFlag(in: stored).label
    }

    var flag: Flag { Flag(wireValue: slot) }

    /// The entry's palette color, as the swipe action's fill.
    var tint: Color { FlagPaletteColor.color(for: color) }

    /// What a press does. The built-in flag under its own name keeps the
    /// words it always had, so nothing changes for someone who never
    /// opened Settings > Flags; any other flag is named: "Urgent" sets it
    /// and "Remove Urgent" clears it.
    func title(isSet: Bool) -> String {
        if keepsClassicWords { return isSet ? "Unflag" : "Flag" }
        return isSet ? "Remove \(label)" : label
    }

    /// The action's glyph, as `ReaderToggleFace` draws every toggle.
    func systemImage(isSet: Bool) -> String {
        isSet ? "flag.slash" : "flag"
    }

    func face(isSet: Bool) -> ReaderToggleFace {
        ReaderToggleFace(title: title(isSet: isSet), systemImage: systemImage(isSet: isSet))
    }

    /// The menu bar's item, which names both directions because it cannot
    /// see the selection: "Flag/Unflag", or "Urgent/Remove Urgent".
    var commandTitle: String {
        "\(title(isSet: false))/\(title(isSet: true))"
    }

    /// The menu bar's title while no window has given it a flag to name;
    /// the item is dimmed then.
    static let idleCommandTitle = "Flag/Unflag"

    private var keepsClassicWords: Bool {
        slot == FlagPalette.systemSlot && label == FlagPalette.defaultSystemEntry.label
    }
}

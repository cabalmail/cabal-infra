import SwiftUI
import CabalmailKit

/// The flag a one-press control sets and clears, and the words and color
/// it does it in: the swipe action, the list and reader shortcuts, the
/// first item of the row and selection menus, the bulk bar's button and
/// the reader's flag button.
///
/// Mail's controls act on the palette's default flag, the first enabled
/// entry of Settings > Flags (`defaultFlag(in:)`). A feed item has one
/// mark, the server's flag, so the feed's controls act on that flag's
/// entry whatever its position (`systemFlag(in:)`).
///
/// Both are nil when there is nothing to act on. In the app that takes a
/// stored palette whose built-in entry is switched off, since the entry's
/// editor has no such switch; the controls then hide or dim instead of
/// falling back to a flag the user turned off.
struct FlagToggle: Equatable {
    let slot: String
    let label: String
    let color: String

    init(_ entry: FlagPaletteEntry) {
        slot = entry.slot
        label = entry.label
        color = entry.color
    }

    /// The flag the mail controls toggle: the first enabled entry of the
    /// effective palette.
    static func defaultFlag(in stored: [FlagPaletteEntry]) -> FlagToggle? {
        FlagPalette.defaultEntry(in: stored).map(FlagToggle.init)
    }

    /// The built-in flag's entry, for the feed controls and for the
    /// filters, which the server can only run on that flag. Nil while the
    /// entry is disabled.
    static func systemFlag(in stored: [FlagPaletteEntry]) -> FlagToggle? {
        FlagPalette.effective(stored)
            .first { $0.slot == FlagPalette.systemSlot && $0.enabled }
            .map(FlagToggle.init)
    }

    /// The built-in flag's name as a state rather than an action, for the
    /// Flagged filter pills and the search sheet's toggle: its entry's
    /// label, enabled or not.
    static func systemFlagName(in stored: [FlagPaletteEntry]) -> String {
        FlagPalette.effective(stored).first { $0.slot == FlagPalette.systemSlot }?.label
            ?? FlagPalette.defaultSystemEntry.label
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

    /// The menu bar's title while there is no flag to toggle; the item is
    /// dimmed then.
    static let idleCommandTitle = "Flag/Unflag"

    private var keepsClassicWords: Bool {
        slot == FlagPalette.systemSlot && label == FlagPalette.defaultSystemEntry.label
    }
}

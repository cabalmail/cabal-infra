import Foundation
import CabalmailKit

/// A row of the Flagged pill's menu on a list bar.
enum FlagFilterChoice: Hashable {
    /// One flag of Settings > Flags, the built-in one included.
    case flag(slot: String)
    case any
    case clear
}

/// What a list bar draws for its Flagged pill while the pill is a menu.
struct FlagFilterPillModel {
    /// The pill's word as drawn: a long flag name is cut short.
    let label: String
    /// The whole name, for VoiceOver.
    let name: String
    let isOn: Bool
    /// The number after the label; nil draws none.
    let count: Int?
    /// A number whose room the pill keeps while `count` is on its way, so
    /// the bar does not change shape a moment after a pick.
    let reservedCount: Int?
    let rows: [ReaderMenuRow<FlagFilterChoice>]
}

/// The Flagged pill as a menu: when a list bar's pill is one, its rows,
/// and the words and number on the pill.
///
/// With only the built-in flag in Settings > Flags the pill is the toggle
/// it always was. Once there is a flag of the user's own, a tap or a click
/// opens a menu instead (no chevron, no second gesture): a row for every
/// flag in the palette's order, then Any flag, then Clear filter. The
/// folder list and the feed list draw it the same way from this.
///
/// `current` is what the pill is lit on: nil while it is not lit, the
/// built-in flag's slot for the Flagged filter both lists have always had
/// (remembered per folder or feed), and otherwise a pick, which lasts for
/// the visit and is recorded nowhere.
enum FlagFilterMenuPolicy {
    static let anyFlagLabel = "Any flag"
    static let clearLabel = "Clear filter"

    /// The most characters of a flag's name the lit pill draws. A name may
    /// run to 32 (`FlagPalette.maxLabelLength`), and a pill that long, with
    /// its count, is wider than a narrow list column has room for beside
    /// the bar's other controls. The menu row and VoiceOver keep the whole
    /// name.
    static let drawnNameLimit = 20

    private static let builtIn = FlagCriterion.slot(FlagPalette.systemSlot)

    /// Whether the Flagged pill is a menu. It is while the palette holds a
    /// flag besides the built-in one, and for as long as a pick is in
    /// force: a pick whose flag was deleted in the meantime, the palette's
    /// last custom one, still needs its name on the pill and Clear filter
    /// under it.
    static func offersMenu(palette: [FlagPaletteEntry], current: FlagCriterion?) -> Bool {
        if let current, current != builtIn { return true }
        return !FlagPalette.keywordEntries(in: palette).isEmpty
    }

    /// The menu's rows: every flag of the palette in its order, checked
    /// when the list is narrowed to it; Any flag; and Clear filter, live
    /// only while this pill is lit. A slot whose flag was deleted is not
    /// offered: Any flag finds what still carries it.
    static func rows(palette: [FlagPaletteEntry], current: FlagCriterion?) -> [ReaderMenuRow<FlagFilterChoice>] {
        var rows = FlagPalette.effective(palette).map { entry in
            ReaderMenuRow(option: FlagFilterChoice.flag(slot: entry.slot), key: entry.slot, label: entry.label,
                          isOn: current == .slot(entry.slot))
        }
        rows.append(ReaderMenuRow(option: .any, key: "any", label: anyFlagLabel, isOn: current == .any,
                                  startsGroup: true))
        rows.append(ReaderMenuRow(option: .clear, key: "clear", label: clearLabel, isOn: false,
                                  isEnabled: current != nil, startsGroup: true))
        return rows
    }

    /// What a row asks the list for: a criterion, or nil for Clear filter.
    static func criterion(for choice: FlagFilterChoice) -> FlagCriterion? {
        switch choice {
        case .flag(let slot): return .slot(slot)
        case .any: return .any
        case .clear: return nil
        }
    }

    /// The pill's word, whole. Unlit, and lit on the built-in flag, it is
    /// that flag's name, as the plain pill's is; under a pick it is the
    /// picked flag's name (its slot id once the flag is gone from the
    /// palette), or Any flag.
    static func name(of current: FlagCriterion?, palette: [FlagPaletteEntry]) -> String {
        switch current {
        case .any?:
            return anyFlagLabel
        case .slot(let slot)? where slot != FlagPalette.systemSlot:
            return palette.first { $0.slot == slot }?.label ?? slot
        default:
            return FlagToggle.systemFlagName(in: palette)
        }
    }

    /// A name as the lit pill draws it under a pick.
    static func drawn(_ name: String) -> String {
        name.count > drawnNameLimit ? String(name.prefix(drawnNameLimit - 1)) + "\u{2026}" : name
    }

    /// The pill for a list bar, or nil while the bar should draw the plain
    /// toggle. `builtInCount` is the number the Flagged pill has always
    /// shown; `pickCount` is the picked flag's, nil until the list has it.
    static func pill(
        palette: [FlagPaletteEntry], current: FlagCriterion?, builtInCount: Int?, pickCount: Int?
    ) -> FlagFilterPillModel? {
        guard offersMenu(palette: palette, current: current) else { return nil }
        let picked = current != nil && current != builtIn
        let name = Self.name(of: current, palette: palette)
        let count = picked ? pickCount : builtInCount
        return FlagFilterPillModel(
            label: picked ? drawn(name) : name,
            name: name,
            isOn: current != nil,
            count: count,
            reservedCount: count == nil ? builtInCount : nil,
            rows: rows(palette: palette, current: current)
        )
    }

    /// Identity for the pill's `Menu`: macOS keeps the AppKit menu it built
    /// the first time the menu opened, checkmarks and row titles included
    /// (`FlagMenuPolicy`), so the menu is replaced whenever a row changes.
    static func identity(_ rows: [ReaderMenuRow<FlagFilterChoice>]) -> String {
        ReaderOptionMenuPolicy.identity(rows)
    }
}

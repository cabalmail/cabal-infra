import XCTest
import CabalmailKit
@testable import CabalmailUI

/// `FlagFilterMenuPolicy`: when a list bar's Flagged pill is a menu, the
/// rows it offers, and the word and number on the pill. Both lists draw
/// their pill from it, and `FlagFilterPill` keeps the plain pill's size.
@MainActor
final class FlagFilterMenuPolicyTests: XCTestCase {
    private let system = FlagPalette.systemSlot
    private let later = "cabal-flag-03"
    private let work = "cabal-flag-05"
    private var builtIn: FlagCriterion { .slot(system) }

    private func entry(_ slot: String, _ label: String) -> FlagPaletteEntry {
        FlagPaletteEntry(slot: slot, label: label, color: "blue")
    }

    private var palette: [FlagPaletteEntry] { [entry(later, "Later"), entry(work, "Work")] }

    // MARK: - When the pill is a menu

    func testThePillIsAMenuOnlyWithAFlagOfTheUsersOwn() {
        XCTAssertFalse(FlagFilterMenuPolicy.offersMenu(palette: [], current: nil))
        XCTAssertFalse(FlagFilterMenuPolicy.offersMenu(palette: [entry(system, "Urgent")], current: builtIn),
                       "the built-in flag renamed is still the only flag")
        XCTAssertTrue(FlagFilterMenuPolicy.offersMenu(palette: [entry(later, "Later")], current: nil))
        XCTAssertNil(FlagFilterMenuPolicy.pill(palette: [], current: builtIn, builtInCount: 3, pickCount: nil))
    }

    /// A pick outlives its flag: with the last custom flag deleted the list
    /// is still narrowed, and a plain pill would name the built-in flag.
    func testAPickKeepsThePillAMenuWhateverThePaletteHolds() {
        XCTAssertTrue(FlagFilterMenuPolicy.offersMenu(palette: [], current: .slot(later)))
        XCTAssertTrue(FlagFilterMenuPolicy.offersMenu(palette: [], current: .any))

        let pill = FlagFilterMenuPolicy.pill(palette: [], current: .slot(later), builtInCount: 3, pickCount: 2)
        XCTAssertEqual(pill?.label, later, "the slot's id once the flag is gone")
        XCTAssertEqual(pill?.rows.map(\.label), ["Flagged", "Any flag", "Clear filter"])
        XCTAssertEqual(pill?.rows.map(\.isOn), [false, false, false], "a deleted flag has no row to check")
        XCTAssertEqual(pill?.rows.last?.isEnabled, true)
    }

    // MARK: - Rows

    func testRowsAreEveryFlagInPaletteOrderThenAnyFlagThenClearFilter() {
        let rows = FlagFilterMenuPolicy.rows(palette: palette, current: nil)

        XCTAssertEqual(rows.map(\.label), ["Flagged", "Later", "Work", "Any flag", "Clear filter"])
        XCTAssertEqual(rows.map(\.option), [.flag(slot: system), .flag(slot: later), .flag(slot: work), .any, .clear])
        XCTAssertEqual(rows.map(\.startsGroup), [false, false, false, true, true])
        XCTAssertEqual(Set(rows.map(\.key)).count, rows.count)
    }

    func testTheBuiltInFlagIsARowWhereThePalettePutsIt() {
        let rows = FlagFilterMenuPolicy.rows(palette: [entry(later, "Later"), entry(system, "Urgent")], current: nil)

        XCTAssertEqual(rows.map(\.label), ["Later", "Urgent", "Any flag", "Clear filter"])
    }

    func testOneRowIsCheckedForWhatThePillIsLitOn() {
        func checked(_ current: FlagCriterion?) -> [String] {
            FlagFilterMenuPolicy.rows(palette: palette, current: current).filter(\.isOn).map(\.label)
        }

        XCTAssertEqual(checked(nil), [], "nothing while the pill is unlit, Unread lit beside it or not")
        XCTAssertEqual(checked(builtIn), ["Flagged"])
        XCTAssertEqual(checked(.slot(work)), ["Work"])
        XCTAssertEqual(checked(.any), ["Any flag"])
    }

    /// Clear filter is the pill's own way off: live while the pill is lit,
    /// on whatever, and not a way to turn off the Unread pill beside it.
    func testClearFilterIsLiveOnlyWhileThePillIsLit() {
        func clear(_ current: FlagCriterion?) -> Bool? {
            FlagFilterMenuPolicy.rows(palette: palette, current: current).last?.isEnabled
        }

        XCTAssertEqual(clear(nil), false)
        XCTAssertEqual(clear(builtIn), true)
        XCTAssertEqual(clear(.slot(later)), true)
        XCTAssertEqual(clear(.any), true)
    }

    func testEachRowAsksForItsCriterion() {
        XCTAssertEqual(FlagFilterMenuPolicy.criterion(for: .flag(slot: later)), .slot(later))
        XCTAssertEqual(FlagFilterMenuPolicy.criterion(for: .flag(slot: system)), builtIn)
        XCTAssertEqual(FlagFilterMenuPolicy.criterion(for: .any), .any)
        XCTAssertNil(FlagFilterMenuPolicy.criterion(for: .clear))
    }

    /// macOS keeps the menu it first built, so a moved checkmark, a renamed
    /// flag or Clear filter coming alive each has to change the identity.
    func testTheMenusIdentityFollowsWhatItsRowsDraw() {
        func identity(_ palette: [FlagPaletteEntry], _ current: FlagCriterion?) -> String {
            FlagFilterMenuPolicy.identity(FlagFilterMenuPolicy.rows(palette: palette, current: current))
        }
        let unlit = identity(palette, nil)

        XCTAssertEqual(identity(palette, nil), unlit)
        XCTAssertNotEqual(identity(palette, builtIn), unlit)
        XCTAssertNotEqual(identity(palette, .slot(later)), identity(palette, .slot(work)))
        XCTAssertNotEqual(identity([entry(later, "Soon"), entry(work, "Work")], nil), unlit)
    }

    // MARK: - The pill's word and number

    func testThePillNamesWhatItIsLitOn() {
        let renamed = [entry(system, "Urgent")] + palette

        XCTAssertEqual(FlagFilterMenuPolicy.name(of: nil, palette: renamed), "Urgent", "unlit, the built-in flag's")
        XCTAssertEqual(FlagFilterMenuPolicy.name(of: builtIn, palette: renamed), "Urgent")
        XCTAssertEqual(FlagFilterMenuPolicy.name(of: nil, palette: palette), FlagToggle.systemFlagName(in: palette))
        XCTAssertEqual(FlagFilterMenuPolicy.name(of: .slot(work), palette: palette), "Work")
        XCTAssertEqual(FlagFilterMenuPolicy.name(of: .any, palette: palette), "Any flag")
        XCTAssertEqual(FlagFilterMenuPolicy.name(of: .slot("cabal-flag-09"), palette: palette), "cabal-flag-09")
    }

    func testTheNumberIsTheBuiltInFlagsUntilAFlagIsPicked() {
        func pill(_ current: FlagCriterion?, pickCount: Int?) -> FlagFilterPillModel? {
            FlagFilterMenuPolicy.pill(palette: palette, current: current, builtInCount: 3, pickCount: pickCount)
        }

        XCTAssertEqual(pill(nil, pickCount: 9)?.count, 3)
        XCTAssertEqual(pill(builtIn, pickCount: 9)?.count, 3)
        XCTAssertEqual(pill(.slot(later), pickCount: 9)?.count, 9)
        XCTAssertEqual(pill(.any, pickCount: 12)?.count, 12)
        XCTAssertEqual(pill(nil, pickCount: nil)?.isOn, false)
        XCTAssertEqual(pill(.any, pickCount: nil)?.isOn, true)
    }

    /// A pick's number arrives after the pick. The pill holds the room for
    /// one meanwhile, so the bar takes its shape once, at the tap.
    func testAPendingNumberKeepsItsRoom() {
        let waiting = FlagFilterMenuPolicy.pill(palette: palette, current: .slot(later), builtInCount: 3,
                                                pickCount: nil)
        let counted = FlagFilterMenuPolicy.pill(palette: palette, current: .slot(later), builtInCount: 3,
                                                pickCount: 9)

        XCTAssertNil(waiting?.count)
        XCTAssertEqual(waiting?.reservedCount, 3)
        XCTAssertNil(counted?.reservedCount)
    }

    /// A flag's name may run to 32 characters. The lit pill draws at most
    /// twenty; the row in the menu and VoiceOver keep it whole.
    func testALongPickedNameIsCutOnThePillOnly() {
        let long = "Waiting on reply from accounting"
        XCTAssertEqual(long.count, FlagPalette.maxLabelLength)
        let named = [entry(later, long), entry(work, String(long.prefix(20)))]

        let pill = FlagFilterMenuPolicy.pill(palette: named, current: .slot(later), builtInCount: 3, pickCount: 1)

        XCTAssertEqual(pill?.label, "Waiting on reply fr\u{2026}")
        XCTAssertEqual(pill?.label.count, FlagFilterMenuPolicy.drawnNameLimit)
        XCTAssertEqual(pill?.name, long)
        XCTAssertEqual(pill?.rows.first { $0.option == .flag(slot: later) }?.label, long)
        XCTAssertEqual(FlagFilterMenuPolicy.drawn(String(long.prefix(20))), "Waiting on reply fro",
                       "a name that fits is drawn whole")
    }

    /// The cut is for a picked flag's name. The built-in flag's is drawn as
    /// the plain pill draws it, unlit and lit, so the pill does not change
    /// its word when a flag of the user's own first appears.
    func testTheBuiltInFlagsNameIsDrawnAsThePlainPillDrawsIt() {
        let long = "A built-in flag with a long name"
        let named = [entry(system, long), entry(later, "Later")]

        for current in [nil, builtIn] {
            let pill = FlagFilterMenuPolicy.pill(palette: named, current: current, builtInCount: 3, pickCount: nil)
            XCTAssertEqual(pill?.label, long)
            XCTAssertEqual(pill?.label, FlagToggle.systemFlagName(in: named))
        }
    }

    /// Two flags may share a name. A row is told from another by its slot,
    /// which is what the menu's rows are identified by.
    func testFlagsOfTheSameNameAreSeparateRows() {
        let rows = FlagFilterMenuPolicy.rows(palette: [entry(later, "Soon"), entry(work, "Soon")], current: .slot(work))

        XCTAssertEqual(rows.map(\.label), ["Flagged", "Soon", "Soon", "Any flag", "Clear filter"])
        XCTAssertEqual(Set(rows.map(\.id)).count, rows.count)
        XCTAssertEqual(rows.map(\.isOn), [false, false, true, false, false])
    }
}

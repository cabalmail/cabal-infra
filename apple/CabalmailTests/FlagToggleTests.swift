import XCTest
import CabalmailKit
@testable import CabalmailUI

/// `FlagToggle`: which flag the one-press controls act on, and what they
/// call it (unified-flags plan, decisions 3, 5 and 6).
final class FlagToggleTests: XCTestCase {
    private func entry(_ slot: String, _ label: String, color: String = "blue") -> FlagPaletteEntry {
        FlagPaletteEntry(slot: slot, label: label, color: color)
    }

    private var system: String { FlagPalette.systemSlot }

    /// A palette as a build from before the Enabled switch was removed
    /// stored it: `enabled` on every entry, false on both.
    private func storedAsSwitchedOff() throws -> [FlagPaletteEntry] {
        try XCTUnwrap(FlagPalette.decode(
            #"[{"color":"red","enabled":false,"label":"Todo","slot":"cabal-flag-03"},"#
                + #"{"color":"yellow","enabled":false,"label":"Urgent","slot":"\\Flagged"}]"#
        ))
    }

    // MARK: - The default flag

    /// Goal 3: someone who never opened Settings > Flags keeps the flag,
    /// the words and the color they had.
    func testAnUntouchedPaletteTogglesTheBuiltInFlagInItsOldWords() {
        let toggle = FlagToggle.defaultFlag(in: [])
        XCTAssertEqual(toggle.flag, .flagged)
        XCTAssertEqual(toggle.color, "yellow")
        XCTAssertEqual(toggle.title(isSet: false), "Flag")
        XCTAssertEqual(toggle.title(isSet: true), "Unflag")
        XCTAssertEqual(toggle.commandTitle, "Flag/Unflag")
    }

    /// Custom flags after the built-in one change nothing: it is still first.
    func testFlagsAddedBelowLeaveTheBuiltInFlagTheDefault() {
        let toggle = FlagToggle.defaultFlag(in: [entry("cabal-flag-01", "Todo")])
        XCTAssertEqual(toggle.flag, .flagged)
    }

    func testAFlagMovedToTheTopBecomesTheDefault() {
        let palette = [entry("cabal-flag-03", "Todo", color: "red"), entry(system, "Flagged", color: "yellow")]
        let toggle = FlagToggle.defaultFlag(in: palette)
        XCTAssertEqual(toggle.flag, .keyword("cabal-flag-03"))
        XCTAssertEqual(toggle.color, "red")
        XCTAssertEqual(toggle.title(isSet: false), "Todo")
        XCTAssertEqual(toggle.title(isSet: true), "Remove Todo")
        XCTAssertEqual(toggle.commandTitle, "Todo/Remove Todo")
    }

    /// The first flag is the default whatever an older build stored about
    /// it: a flag cannot be switched off, so nothing is passed over.
    func testAFlagStoredAsSwitchedOffIsStillTheDefaultWhenFirst() throws {
        let toggle = FlagToggle.defaultFlag(in: try storedAsSwitchedOff())
        XCTAssertEqual(toggle.flag, .keyword("cabal-flag-03"))
        XCTAssertEqual(toggle.title(isSet: false), "Todo")
    }

    // MARK: - Words

    /// A renamed built-in flag is named like any other; only the label
    /// decides, so a recolor alone keeps "Flag" and "Unflag".
    func testTheBuiltInFlagTakesItsNewNameOnceRenamed() {
        let renamed = FlagToggle.defaultFlag(in: [entry(system, "Urgent", color: "red")])
        XCTAssertEqual(renamed.title(isSet: false), "Urgent")
        XCTAssertEqual(renamed.title(isSet: true), "Remove Urgent")

        let recolored = FlagToggle.defaultFlag(in: [entry(system, "Flagged", color: "red")])
        XCTAssertEqual(recolored.title(isSet: false), "Flag")
        XCTAssertEqual(recolored.title(isSet: true), "Unflag")
    }

    /// A custom flag that happens to be called "Flagged" is still named:
    /// "Flag" and "Unflag" are the built-in flag's words.
    func testACustomFlagNamedFlaggedIsStillNamed() {
        let palette = [entry("cabal-flag-01", "Flagged"), entry(system, "Starred")]
        let toggle = FlagToggle.defaultFlag(in: palette)
        XCTAssertEqual(toggle.title(isSet: false), "Flagged")
        XCTAssertEqual(toggle.title(isSet: true), "Remove Flagged")
    }

    func testTheGlyphShowsTheAction() {
        let toggle = FlagToggle.defaultFlag(in: [])
        XCTAssertEqual(toggle.systemImage(isSet: false), "flag")
        XCTAssertEqual(toggle.systemImage(isSet: true), "flag.slash")
        XCTAssertEqual(toggle.face(isSet: true), ReaderToggleFace.flag(isFlagged: true))
        XCTAssertEqual(toggle.face(isSet: false), ReaderToggleFace.flag(isFlagged: false))
    }

    // MARK: - The built-in flag, for the filters

    /// The Flagged filters are on the built-in flag, so they follow that
    /// entry wherever it sits in the palette.
    func testTheFilterFlagIsTheBuiltInEntryWhateverItsPosition() {
        let palette = [entry("cabal-flag-03", "Todo"), entry(system, "Urgent", color: "red")]
        let toggle = FlagToggle.systemFlag(in: palette)
        XCTAssertEqual(toggle.flag, .flagged)
        XCTAssertEqual(toggle.color, "red")
        XCTAssertEqual(toggle.title(isSet: false), "Urgent")
        XCTAssertEqual(FlagToggle.systemFlag(in: []).title(isSet: true), "Unflag")
    }

    /// The filters never lose their flag: a built-in entry stored as
    /// switched off is the filters' flag all the same.
    func testTheFilterFlagIsThereForABuiltInEntryStoredAsSwitchedOff() throws {
        let toggle = FlagToggle.systemFlag(in: try storedAsSwitchedOff())
        XCTAssertEqual(toggle.flag, .flagged)
        XCTAssertEqual(toggle.title(isSet: false), "Urgent")
    }

    /// The pills and the search toggle name the state.
    func testTheFilterNameFollowsTheBuiltInEntrysLabel() throws {
        XCTAssertEqual(FlagToggle.systemFlagName(in: []), "Flagged")
        XCTAssertEqual(FlagToggle.systemFlagName(in: [entry("cabal-flag-01", "Todo")]), "Flagged")
        XCTAssertEqual(
            FlagToggle.systemFlagName(in: [entry("cabal-flag-01", "Todo"), entry(system, "Urgent")]), "Urgent"
        )
        XCTAssertEqual(FlagToggle.systemFlagName(in: try storedAsSwitchedOff()), "Urgent")
    }

    // MARK: - Filter pills

    func testTheFlaggedPillCarriesTheEntrysName() {
        let palette = [entry(system, "Urgent")]
        XCTAssertEqual(MessageFilter.flagged.label(palette: palette), "Urgent")
        XCTAssertEqual(MessageFilter.flagged.label(palette: []), "Flagged")
        XCTAssertEqual(MessageFilter.unread.label(palette: palette), "Unread")
        XCTAssertEqual(MessageFilter.all.label(palette: palette), "All")
    }
}

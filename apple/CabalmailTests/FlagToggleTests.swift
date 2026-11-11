import XCTest
import CabalmailKit
@testable import CabalmailUI

/// `FlagToggle`: which flag the one-press controls act on, and what they
/// call it (unified-flags plan, decisions 3, 5 and 6).
final class FlagToggleTests: XCTestCase {
    private func entry(
        _ slot: String, _ label: String, color: String = "blue", enabled: Bool = true
    ) -> FlagPaletteEntry {
        FlagPaletteEntry(slot: slot, label: label, color: color, enabled: enabled)
    }

    private var system: String { FlagPalette.systemSlot }

    // MARK: - The default flag

    /// Goal 3: someone who never opened Settings > Flags keeps the flag,
    /// the words and the color they had.
    func testAnUntouchedPaletteTogglesTheBuiltInFlagInItsOldWords() throws {
        let toggle = try XCTUnwrap(FlagToggle.defaultFlag(in: []))
        XCTAssertEqual(toggle.flag, .flagged)
        XCTAssertEqual(toggle.color, "yellow")
        XCTAssertEqual(toggle.title(isSet: false), "Flag")
        XCTAssertEqual(toggle.title(isSet: true), "Unflag")
        XCTAssertEqual(toggle.commandTitle, "Flag/Unflag")
    }

    /// Custom flags after the built-in one change nothing: it is still first.
    func testFlagsAddedBelowLeaveTheBuiltInFlagTheDefault() {
        let toggle = FlagToggle.defaultFlag(in: [entry("cabal-flag-01", "Todo")])
        XCTAssertEqual(toggle?.flag, .flagged)
    }

    func testAFlagMovedToTheTopBecomesTheDefault() throws {
        let palette = [entry("cabal-flag-03", "Todo", color: "red"), entry(system, "Flagged", color: "yellow")]
        let toggle = try XCTUnwrap(FlagToggle.defaultFlag(in: palette))
        XCTAssertEqual(toggle.flag, .keyword("cabal-flag-03"))
        XCTAssertEqual(toggle.color, "red")
        XCTAssertEqual(toggle.title(isSet: false), "Todo")
        XCTAssertEqual(toggle.title(isSet: true), "Remove Todo")
        XCTAssertEqual(toggle.commandTitle, "Todo/Remove Todo")
    }

    func testADisabledFlagIsPassedOverForTheNextOne() {
        let palette = [
            entry("cabal-flag-03", "Todo", enabled: false),
            entry("cabal-flag-01", "Later"),
            entry(system, "Flagged"),
        ]
        XCTAssertEqual(FlagToggle.defaultFlag(in: palette)?.flag, .keyword("cabal-flag-01"))
    }

    /// Decision 3's degenerate case: no fallback to a flag the palette
    /// says is off.
    func testThereIsNoDefaultFlagWhenEveryEntryIsDisabled() {
        let palette = [entry(system, "Flagged", enabled: false), entry("cabal-flag-01", "Todo", enabled: false)]
        XCTAssertNil(FlagToggle.defaultFlag(in: palette))
    }

    // MARK: - Words

    /// A renamed built-in flag is named like any other; only the label
    /// decides, so a recolor alone keeps "Flag" and "Unflag".
    func testTheBuiltInFlagTakesItsNewNameOnceRenamed() throws {
        let renamed = try XCTUnwrap(FlagToggle.defaultFlag(in: [entry(system, "Urgent", color: "red")]))
        XCTAssertEqual(renamed.title(isSet: false), "Urgent")
        XCTAssertEqual(renamed.title(isSet: true), "Remove Urgent")

        let recolored = try XCTUnwrap(FlagToggle.defaultFlag(in: [entry(system, "Flagged", color: "red")]))
        XCTAssertEqual(recolored.title(isSet: false), "Flag")
        XCTAssertEqual(recolored.title(isSet: true), "Unflag")
    }

    /// A custom flag that happens to be called "Flagged" is still named:
    /// "Flag" and "Unflag" are the built-in flag's words.
    func testACustomFlagNamedFlaggedIsStillNamed() throws {
        let palette = [entry("cabal-flag-01", "Flagged"), entry(system, "Starred")]
        let toggle = try XCTUnwrap(FlagToggle.defaultFlag(in: palette))
        XCTAssertEqual(toggle.title(isSet: false), "Flagged")
        XCTAssertEqual(toggle.title(isSet: true), "Remove Flagged")
    }

    func testTheGlyphShowsTheAction() throws {
        let toggle = try XCTUnwrap(FlagToggle.defaultFlag(in: []))
        XCTAssertEqual(toggle.systemImage(isSet: false), "flag")
        XCTAssertEqual(toggle.systemImage(isSet: true), "flag.slash")
        XCTAssertEqual(toggle.face(isSet: true), ReaderToggleFace.flag(isFlagged: true))
        XCTAssertEqual(toggle.face(isSet: false), ReaderToggleFace.flag(isFlagged: false))
    }

    // MARK: - The built-in flag, for feeds and filters

    /// A feed item has the server's flag and no other, so the feed's
    /// controls follow that entry wherever it sits in the palette.
    func testTheFeedFlagIsTheBuiltInEntryWhateverItsPosition() throws {
        let palette = [entry("cabal-flag-03", "Todo"), entry(system, "Urgent", color: "red")]
        let toggle = try XCTUnwrap(FlagToggle.systemFlag(in: palette))
        XCTAssertEqual(toggle.flag, .flagged)
        XCTAssertEqual(toggle.color, "red")
        XCTAssertEqual(toggle.title(isSet: false), "Urgent")
        XCTAssertEqual(FlagToggle.systemFlag(in: [])?.title(isSet: true), "Unflag")
    }

    func testTheFeedFlagIsGoneWhileItsEntryIsDisabled() {
        let palette = [entry(system, "Flagged", enabled: false), entry("cabal-flag-01", "Todo")]
        XCTAssertNil(FlagToggle.systemFlag(in: palette))
    }

    /// The pills and the search toggle name the state, and keep the name
    /// even for a disabled entry (a lit pill still has to say what it is).
    func testTheFilterNameFollowsTheBuiltInEntrysLabel() {
        XCTAssertEqual(FlagToggle.systemFlagName(in: []), "Flagged")
        XCTAssertEqual(FlagToggle.systemFlagName(in: [entry("cabal-flag-01", "Todo")]), "Flagged")
        XCTAssertEqual(
            FlagToggle.systemFlagName(in: [entry("cabal-flag-01", "Todo"), entry(system, "Urgent")]), "Urgent"
        )
        XCTAssertEqual(FlagToggle.systemFlagName(in: [entry(system, "Urgent", enabled: false)]), "Urgent")
    }

    // MARK: - Filter pills

    func testTheFlaggedPillCarriesTheEntrysName() {
        let palette = [entry(system, "Urgent")]
        XCTAssertEqual(MessageFilter.flagged.label(palette: palette), "Urgent")
        XCTAssertEqual(MessageFilter.flagged.label(palette: []), "Flagged")
        XCTAssertEqual(MessageFilter.unread.label(palette: palette), "Unread")
        XCTAssertEqual(MessageFilter.all.label(palette: palette), "All")
    }

    func testTheFlaggedPillLeavesWithADisabledEntryUnlessItIsLit() {
        let disabled = [entry(system, "Flagged", enabled: false)]
        XCTAssertEqual(MessageFilter.pills(palette: [], lit: .all), [.unread, .flagged])
        XCTAssertEqual(MessageFilter.pills(palette: disabled, lit: .all), [.unread])
        XCTAssertEqual(MessageFilter.pills(palette: disabled, lit: .unread), [.unread])
        XCTAssertEqual(
            MessageFilter.pills(palette: disabled, lit: .flagged), [.unread, .flagged],
            "a lit pill stays, so it can be switched off"
        )
    }
}

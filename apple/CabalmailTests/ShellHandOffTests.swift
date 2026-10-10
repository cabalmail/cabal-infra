import XCTest
@testable import CabalmailUI

/// The rules for what a window carries across a change of layout shell
/// (`ShellHandOff`). `SceneNavigatorShellTransitionTests` covers the same
/// rules as the navigator applies them, with a real search model and tab.
final class ShellHandOffTests: XCTestCase {
    // MARK: Turning to the tabs

    func testNarrowingMidSearchShowsTheSearchTab() {
        var handOff = ShellHandOff()
        XCTAssertEqual(
            handOff.layoutChanged(wasWide: true, isWide: false, tab: .mail, searchIsEngaged: true),
            .showTab(.search)
        )
    }

    func testNarrowingWithNoSearchShowsNothingNew() {
        var handOff = ShellHandOff()
        XCTAssertEqual(
            handOff.layoutChanged(wasWide: true, isWide: false, tab: .feeds, searchIsEngaged: false),
            .nothing
        )
    }

    /// The sheet is what the user was looking at, so it wins over a search
    /// sitting behind it.
    func testAnOpenSheetOutranksTheSearchAndBecomesTheTab() {
        var handOff = ShellHandOff()
        handOff.openSettingsSheet()
        XCTAssertEqual(
            handOff.layoutChanged(wasWide: true, isWide: false, tab: .mail, searchIsEngaged: true),
            .showTab(.settings)
        )
        XCTAssertFalse(handOff.settingsSheetOpen, "the tab layouts have no sheet")
    }

    /// A window that opens narrow reports tabs to tabs.
    func testTheFirstReportIsNotANarrowing() {
        var handOff = ShellHandOff()
        XCTAssertEqual(
            handOff.layoutChanged(wasWide: false, isWide: false, tab: .mail, searchIsEngaged: true),
            .nothing
        )
    }

    // MARK: Turning to the split

    func testWideningFromTheSettingsTabOpensTheSheet() {
        var handOff = ShellHandOff()
        XCTAssertEqual(
            handOff.layoutChanged(wasWide: false, isWide: true, tab: .settings, searchIsEngaged: false),
            .nothing
        )
        XCTAssertTrue(handOff.settingsSheetOpen)
    }

    func testWideningFromTheSearchTabKeepsItsSearch() {
        var handOff = ShellHandOff()
        XCTAssertEqual(
            handOff.layoutChanged(wasWide: false, isWide: true, tab: .search, searchIsEngaged: true),
            .nothing
        )
    }

    func testWideningFromAnyOtherTabEndsALeftoverSearch() {
        for tab in [CompactTab.mail, .feeds, .addresses, .folders] {
            var handOff = ShellHandOff()
            XCTAssertEqual(
                handOff.layoutChanged(wasWide: false, isWide: true, tab: tab, searchIsEngaged: true),
                .endLeftoverSearch,
                "\(tab)"
            )
            XCTAssertFalse(handOff.settingsSheetOpen, "\(tab)")
        }
    }

    /// Both at once: the Settings tab over a search left in the Search tab.
    func testWideningFromSettingsOpensTheSheetAndEndsALeftoverSearch() {
        var handOff = ShellHandOff()
        XCTAssertEqual(
            handOff.layoutChanged(wasWide: false, isWide: true, tab: .settings, searchIsEngaged: true),
            .endLeftoverSearch
        )
        XCTAssertTrue(handOff.settingsSheetOpen)
    }

    /// A split that stays a split (a resize, a rotation) hands nothing off.
    func testALayoutThatStaysWideDoesNothing() {
        var handOff = ShellHandOff()
        handOff.openSettingsSheet()
        XCTAssertEqual(
            handOff.layoutChanged(wasWide: true, isWide: true, tab: .settings, searchIsEngaged: true),
            .nothing
        )
        XCTAssertTrue(handOff.settingsSheetOpen)
    }

    // MARK: Dismissing the sheet

    func testDismissingASheetThatCameFromTheSettingsTabReturnsTheTab() {
        var handOff = ShellHandOff()
        _ = handOff.layoutChanged(wasWide: false, isWide: true, tab: .settings, searchIsEngaged: false)
        XCTAssertTrue(handOff.sheetDismissed(isShowing: true, tab: .settings))
        XCTAssertFalse(handOff.settingsSheetOpen)
    }

    func testDismissingASheetOpenedOnTheSplitMovesNoTab() {
        var handOff = ShellHandOff()
        handOff.openSettingsSheet()
        XCTAssertFalse(handOff.sheetDismissed(isShowing: true, tab: .mail))
        XCTAssertFalse(handOff.settingsSheetOpen)
    }

    /// A fold takes the sheet down with the split and the view reports that
    /// as a dismissal; with no sheet showing it changes nothing, so the fold
    /// still finds the sheet open and lands on the Settings tab.
    func testADismissalWithNoSheetShowingChangesNothing() {
        var handOff = ShellHandOff()
        handOff.openSettingsSheet()
        XCTAssertFalse(handOff.sheetDismissed(isShowing: false, tab: .mail))
        XCTAssertTrue(handOff.settingsSheetOpen)
    }
}

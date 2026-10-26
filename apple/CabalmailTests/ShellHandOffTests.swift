import XCTest
import CabalmailKit
@testable import CabalmailUI

/// The rules for what a window carries across a change of layout shell
/// (`ShellHandOff`). `SceneNavigatorShellTransitionTests` covers the same
/// rules as the navigator applies them, with a real search model and tab.
final class ShellHandOffTests: XCTestCase {
    private let result = TestFixtures.makeEnvelope(uid: 9, messageId: "<nine@example.com>")

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

    // MARK: The open result (#2184)

    /// The result goes with the search: the Search tab takes it on appear.
    func testACarriedSearchKeepsTheResultItHasOpen() {
        var handOff = ShellHandOff()
        handOff.searchResultChanged(result)
        XCTAssertEqual(
            handOff.layoutChanged(wasWide: true, isWide: false, tab: .mail, searchIsEngaged: true),
            .showTab(.search)
        )
        XCTAssertEqual(handOff.searchResult, result)
        XCTAssertEqual(handOff.takeSearchResult(), result)
        XCTAssertNil(handOff.searchResult, "taken once, so a later appearance pushes nothing")
        XCTAssertNil(handOff.takeSearchResult())
    }

    func testWideningFromTheSearchTabKeepsTheResultItHasOpen() {
        var handOff = ShellHandOff()
        handOff.searchResultChanged(result)
        XCTAssertEqual(
            handOff.layoutChanged(wasWide: false, isWide: true, tab: .search, searchIsEngaged: true),
            .nothing
        )
        XCTAssertEqual(handOff.takeSearchResult(), result)
    }

    /// A narrowing with no search to carry: whatever the window last read in
    /// search is not the tab layout's to re-open.
    func testNarrowingWithNoSearchDropsAStaleResult() {
        var handOff = ShellHandOff()
        handOff.searchResultChanged(result)
        XCTAssertEqual(
            handOff.layoutChanged(wasWide: true, isWide: false, tab: .mail, searchIsEngaged: false),
            .nothing
        )
        XCTAssertNil(handOff.searchResult)
    }

    /// The search itself ends, so the result goes with it: the split would
    /// otherwise reopen a result whose search it just cleared.
    func testEndingALeftoverSearchDropsItsResult() {
        var handOff = ShellHandOff()
        handOff.searchResultChanged(result)
        XCTAssertEqual(
            handOff.layoutChanged(wasWide: false, isWide: true, tab: .mail, searchIsEngaged: true),
            .endLeftoverSearch
        )
        XCTAssertNil(handOff.searchResult)
    }

    /// The sheet wins the narrowing, but the search is still the window's, so
    /// the result is there when the user reaches the Search tab.
    func testTheSettingsSheetWinningANarrowingKeepsTheResult() {
        var handOff = ShellHandOff()
        handOff.openSettingsSheet()
        handOff.searchResultChanged(result)
        XCTAssertEqual(
            handOff.layoutChanged(wasWide: true, isWide: false, tab: .mail, searchIsEngaged: true),
            .showTab(.settings)
        )
        XCTAssertEqual(handOff.takeSearchResult(), result)
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

import XCTest
import CabalmailKit
@testable import CabalmailUI

/// The Flagged view's pill and words, what it reports to the menus, and
/// its window's name.
final class FlaggedViewWordsTests: XCTestCase {
    private let later = FlagPaletteEntry(slot: FlagPalette.slots[0], label: "Later", color: "blue")
    private let work = FlagPaletteEntry(slot: FlagPalette.slots[1], label: "Work", color: "red")
    private var builtIn: FlagCriterion { .slot(FlagPalette.systemSlot) }

    // MARK: The pill

    func testWithTheBuiltInFlagAloneThereIsNoPill() {
        XCTAssertNil(FlagFilterMenuPolicy.flaggedViewPill(palette: [], current: .any, count: 3))
        XCTAssertNil(FlagFilterMenuPolicy.flaggedViewPill(palette: [], current: builtIn, count: 3))
    }

    func testThePillListsEveryFlagThenAnyFlagAndNoClearFilter() throws {
        let pill = try XCTUnwrap(FlagFilterMenuPolicy.flaggedViewPill(palette: [later, work], current: .any, count: 14))

        XCTAssertEqual(pill.rows.map(\.label), ["Flagged", "Later", "Work", "Any flag"])
        XCTAssertFalse(pill.rows.contains { $0.option == .clear }, "Any flag is the way back")
        XCTAssertEqual(pill.rows.filter(\.isOn).map(\.label), ["Any flag"])
        XCTAssertEqual(pill.label, "Any flag")
        XCTAssertTrue(pill.isOn, "the view is always narrowed to something")
        XCTAssertEqual(pill.count, 14)
    }

    func testAPickNamesThePillAndChecksItsRow() throws {
        let picked = try XCTUnwrap(
            FlagFilterMenuPolicy.flaggedViewPill(palette: [later, work], current: .slot(work.slot), count: nil)
        )
        XCTAssertEqual(picked.label, "Work")
        XCTAssertEqual(picked.rows.filter(\.isOn).map(\.label), ["Work"])
        XCTAssertNil(picked.count)

        let system = try XCTUnwrap(
            FlagFilterMenuPolicy.flaggedViewPill(palette: [later], current: builtIn, count: 2)
        )
        XCTAssertEqual(system.label, "Flagged")
        XCTAssertEqual(system.rows.filter(\.isOn).map(\.label), ["Flagged"])
    }

    /// A pick whose flag was deleted meanwhile, the palette's last custom
    /// one: the pill stays, named by the slot, with Any flag as the way back.
    func testAPickWhoseFlagWasDeletedKeepsThePill() throws {
        let pill = try XCTUnwrap(
            FlagFilterMenuPolicy.flaggedViewPill(palette: [], current: .slot(later.slot), count: 0)
        )

        XCTAssertEqual(pill.label, later.slot)
        XCTAssertEqual(pill.rows.map(\.label), ["Flagged", "Any flag"])
    }

    func testALongNameIsCutOnThePillAndWholeForVoiceOver() throws {
        let long = FlagPaletteEntry(slot: FlagPalette.slots[2], label: String(repeating: "x", count: 30), color: "blue")
        let pill = try XCTUnwrap(
            FlagFilterMenuPolicy.flaggedViewPill(palette: [long], current: .slot(long.slot), count: 1)
        )

        XCTAssertEqual(pill.label.count, FlagFilterMenuPolicy.drawnNameLimit)
        XCTAssertEqual(pill.name, long.label)
    }

    // MARK: Words

    func testTheMailFailureLineSaysWhatTheListIsMissing() {
        XCTAssertEqual(
            FlaggedListWords.mailFailure(.neverLoaded, isOffline: true),
            "Flagged mail needs a connection. Showing flagged feed items only."
        )
        XCTAssertEqual(
            FlaggedListWords.mailFailure(.neverLoaded, isOffline: false),
            "Flagged mail could not be loaded. Showing flagged feed items only."
        )
        XCTAssertEqual(
            FlaggedListWords.mailFailure(.refresh, isOffline: true),
            "Flagged mail could not be refreshed. Showing it as it was last loaded."
        )
        XCTAssertEqual(FlaggedListWords.mailFailure(.nextPage, isOffline: false), FlaggedListWords.nextPageFailed)
    }

    func testTheEmptyWordsNameThePick() {
        XCTAssertEqual(FlaggedListWords.emptyTitle(for: .any, palette: [later]), "No flagged items")
        XCTAssertEqual(FlaggedListWords.emptyTitle(for: .slot(later.slot), palette: [later]), "No items marked Later")
        XCTAssertEqual(FlaggedListWords.emptyTitle(for: builtIn, palette: [later]), "No items marked Flagged")
        XCTAssertNotEqual(
            FlaggedListWords.emptyDescription(for: .any), FlaggedListWords.emptyDescription(for: builtIn)
        )
    }

    /// The entry and the title read a fixed word, not the built-in flag's
    /// name, which the user can change.
    func testTheViewsNameIsAFixedWord() {
        XCTAssertEqual(SmartView.flagged.title, "Flagged")
    }

    // MARK: The window's name

    func testTheWindowIsNamedForTheViewWhileItIsInFront() {
        XCTAssertEqual(
            MainWindowTitle.title(
                isWide: true, splitShowsFeeds: false, compactTab: .mail, folderName: "INBOX", showsFlagged: true
            ),
            "Flagged"
        )
        XCTAssertEqual(
            MainWindowTitle.title(
                isWide: false, splitShowsFeeds: false, compactTab: .feeds, folderName: nil, showsFlagged: true
            ),
            "Flagged"
        )
        XCTAssertEqual(
            MainWindowTitle.title(isWide: true, splitShowsFeeds: false, compactTab: .mail, folderName: "INBOX"),
            "INBOX"
        )
    }

    // MARK: What the menus are told

    func testOnTheViewTheMenusActOnTheOpenRowWhicheverMediumItIs() {
        let message = FlaggedRow.mail(Envelope(uid: 1, from: [], folder: "INBOX"), MessageRef(folder: "INBOX", uid: 1))
        let article = FlaggedRow.feed(RssItem(feedId: "f", itemId: "a", sortKey: "a"))

        let onMessage = FlaggedMenuReport(showsFlagged: true, item: message)
        XCTAssertTrue(onMessage.hasMessage(else: false))
        XCTAssertEqual(onMessage.messageCount(else: 5), 1, "the list beneath's selection is not this view's")
        XCTAssertFalse(onMessage.hasFeedItem(else: true))

        let onArticle = FlaggedMenuReport(showsFlagged: true, item: article)
        XCTAssertFalse(onArticle.hasMessage(else: true))
        XCTAssertEqual(onArticle.messageCount(else: 5), 0)
        XCTAssertTrue(onArticle.hasFeedItem(else: false))

        let nothingOpen = FlaggedMenuReport(showsFlagged: true, item: nil)
        XCTAssertFalse(nothingOpen.hasMessage(else: true))
        XCTAssertFalse(nothingOpen.hasFeedItem(else: true))
    }

    func testOffTheViewEachShellsOwnAnswerStands() {
        let off = FlaggedMenuReport(showsFlagged: false, item: nil)

        XCTAssertTrue(off.hasMessage(else: true))
        XCTAssertEqual(off.messageCount(else: 5), 5)
        XCTAssertTrue(off.hasFeedItem(else: true))
        XCTAssertFalse(off.hasFeedItem(else: false))
    }
}

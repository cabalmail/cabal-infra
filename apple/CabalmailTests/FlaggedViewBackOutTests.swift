import XCTest
import SwiftUI
import CabalmailKit
@testable import CabalmailUI

/// Back from the Flagged view's list on a collapsed stack that a change of
/// layout shell built. The wide layout always has a folder or a feed list
/// open beneath the view, and the stack that takes the view over inherits
/// it. Back then has to leave that medium on its own first column with
/// nothing picked, as its own Back does: a row left picked in the list the
/// stack lands on pushes the stack forward again, which on a Duo closed
/// over the view left its list on screen with no title, a second Back away
/// from the folders.
@MainActor
final class FlaggedViewBackOutTests: XCTestCase {
    private var windows: FlaggedWindows!
    private var inbox: Folder { windows.inbox }
    private var message: FlaggedRow { windows.message }

    override func setUp() async throws {
        try await super.setUp()
        windows = try FlaggedWindows()
    }

    override func tearDown() async throws {
        windows.tearDown()
        try await super.tearDown()
    }

    /// The split on INBOX with the view over it, then narrowed: the Mail
    /// tab's stack.
    private func narrowedOntoTheView() async -> (navigator: SceneNavigator, stack: UUID) {
        let (navigator, wide) = await windows.wideWindow()
        navigator.showFlagged(from: wide, door: .split)
        let stack = UUID()
        await navigator.mailTreeAppeared(stack, isWide: false, startsOnFolderList: true)
        return (navigator, stack)
    }

    func testBackFromTheListAfterNarrowingLeavesTheFolderListWithNothingPicked() async throws {
        let (navigator, stack) = await narrowedOntoTheView()
        XCTAssertTrue(navigator.flaggedIsOpen(in: stack, door: .mail))
        XCTAssertEqual(navigator.folder(in: stack), inbox, "the split's folder is beneath the view")
        XCTAssertEqual(navigator.compactColumn(in: stack), .content, "and its list is where mail's stack stands")

        XCTAssertTrue(navigator.setFlaggedColumn(.sidebar, from: stack, door: .mail))

        XCTAssertNil(navigator.folder(in: stack), "no folder row is left picked to push the stack forward")
        XCTAssertEqual(navigator.compactColumn(in: stack), .sidebar)
        XCTAssertEqual(navigator.flaggedColumn(in: stack, door: .mail), .sidebar)
        XCTAssertFalse(navigator.flaggedIsOpen(in: stack, door: .mail))
    }

    /// The same Back from the view's reader, in one move to the first
    /// column.
    func testBackFromTheReaderAfterNarrowingLeavesTheFolderListToo() async throws {
        let (navigator, stack) = await narrowedOntoTheView()
        navigator.selectFlaggedItem(message, from: stack, door: .mail)

        XCTAssertTrue(navigator.setFlaggedColumn(.sidebar, from: stack, door: .mail))

        XCTAssertNil(navigator.folder(in: stack))
        XCTAssertEqual(navigator.compactColumn(in: stack), .sidebar)
        XCTAssertNil(navigator.route.smartView)
    }

    /// Back to the view's own list is not Back out of it: the folder
    /// beneath stays where it was.
    func testBackFromTheReaderToTheListLeavesTheFolderBeneath() async throws {
        let (navigator, stack) = await narrowedOntoTheView()
        navigator.selectFlaggedItem(message, from: stack, door: .mail)

        XCTAssertTrue(navigator.setFlaggedColumn(.content, from: stack, door: .mail))

        XCTAssertEqual(navigator.folder(in: stack), inbox)
        XCTAssertTrue(navigator.flaggedIsOpen(in: stack, door: .mail))
    }

    /// The Feeds tab's stack, taking over a view the split showed over a
    /// feed list.
    func testBackFromTheListInTheFeedsTabLeavesItsListOfFeedsWithNothingPicked() async throws {
        let (navigator, wide) = await windows.wideWindow()
        navigator.showFeeds(.all)
        navigator.showFlagged(from: wide, door: .split)
        XCTAssertEqual(navigator.flaggedPlace.state.door, .feeds)
        let stack = UUID()
        await navigator.mailTreeAppeared(stack, isWide: false, startsOnFolderList: true)
        let feeds = UUID()
        await navigator.feedTreeAppeared(feeds)
        XCTAssertTrue(navigator.flaggedIsOpen(in: feeds, door: .feeds))
        XCTAssertEqual(navigator.feeds.scope, .all, "the split's feed list is beneath the view")

        XCTAssertTrue(navigator.setFlaggedColumn(.sidebar, from: feeds, door: .feeds))

        XCTAssertNil(navigator.feeds.scope, "no feed row is left picked to push the stack forward")
        XCTAssertEqual(navigator.feeds.column(in: feeds), .sidebar)
        XCTAssertEqual(navigator.flaggedColumn(in: feeds, door: .feeds), .sidebar)
    }

    // MARK: A door left named

    /// A stack that backed out of the view goes on drawing it while it
    /// slides away, by leaving its door named. The next layout's trees were
    /// never sliding it anywhere: they start without it, or the door would
    /// hold the new stack on its first column whatever the window opened in
    /// between.
    func testAViewBackedOutOfIsGoneFromTheNextLayoutsTrees() async throws {
        let tabs = await windows.tabWindow()
        let navigator = tabs.navigator
        navigator.showFlagged(from: tabs.mail, door: .mail)
        XCTAssertTrue(navigator.setFlaggedColumn(.sidebar, from: tabs.mail, door: .mail))
        XCTAssertTrue(navigator.flaggedOccupies(tabs.mail, door: .mail), "still drawn, sliding away")

        let wide = UUID()
        await navigator.mailTreeAppeared(wide, isWide: true)
        let stack = UUID()
        await navigator.mailTreeAppeared(stack, isWide: false, startsOnFolderList: true)

        XCTAssertFalse(navigator.flaggedOccupies(stack, door: .mail))
        XCTAssertNil(navigator.flaggedColumn(in: stack, door: .mail), "the stack's column is mail's own")
    }

    // MARK: What the session keeps of a closed row

    /// A message opened from the view in a tab with no folder beneath, then
    /// closed: the session no longer names it as open. Left named, the next
    /// layout's landing (the Duo opening) reopened it in the split.
    func testAMessageClosedOverNoFolderIsNoLongerTheSessionsOpenMessage() async throws {
        let tabs = await windows.tabWindow()
        let navigator = tabs.navigator
        navigator.showFlagged(from: tabs.mail, door: .mail)
        navigator.selectFlaggedItem(message, from: tabs.mail, door: .mail)
        XCTAssertTrue(windows.coordinator.session.hasMessage)

        XCTAssertTrue(navigator.setFlaggedColumn(.content, from: tabs.mail, door: .mail))

        XCTAssertFalse(windows.coordinator.session.hasMessage)
        XCTAssertEqual(windows.coordinator.session.folder, "Lists", "the folder it was read in is where mail was")
    }

    /// The same when Back leaves the reader and the view in one move.
    func testAMessageLeftByClosingTheViewIsNoLongerTheSessionsOpenMessage() async throws {
        let tabs = await windows.tabWindow()
        let navigator = tabs.navigator
        navigator.showFlagged(from: tabs.mail, door: .mail)
        navigator.selectFlaggedItem(message, from: tabs.mail, door: .mail)

        XCTAssertTrue(navigator.setFlaggedColumn(.sidebar, from: tabs.mail, door: .mail))

        XCTAssertFalse(windows.coordinator.session.hasMessage)
    }

    func testAnArticleClosedOverNoFeedListIsNoLongerTheSessionsOpenItem() async throws {
        let tabs = await windows.tabWindow()
        let navigator = tabs.navigator
        navigator.showTab(.feeds)
        navigator.showFlagged(from: tabs.feeds, door: .feeds)
        navigator.selectFlaggedItem(windows.article, from: tabs.feeds, door: .feeds)
        XCTAssertEqual(windows.coordinator.session.feedItemSortKey, "a")

        XCTAssertTrue(navigator.setFlaggedColumn(.content, from: tabs.feeds, door: .feeds))

        XCTAssertNil(windows.coordinator.session.feedItemSortKey)
    }

    func testAHandOffOfAViewBackedOutOfDropsItsDoor() {
        var state = FlaggedNavigationState()
        _ = state.open(from: .mail)
        _ = state.setColumn(.sidebar)
        XCTAssertEqual(state.door, .mail)

        state.handOff()

        XCTAssertNil(state.door)
        XCTAssertNil(state.parked)
    }

    func testAHandOffOfAnOpenViewKeepsItsDoor() {
        var state = FlaggedNavigationState()
        _ = state.open(from: .feeds)

        state.handOff()

        XCTAssertEqual(state.door, .feeds)
        XCTAssertTrue(state.isOpen)
    }
}

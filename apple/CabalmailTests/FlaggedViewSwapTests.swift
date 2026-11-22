import XCTest
import SwiftUI
import CabalmailKit
@testable import CabalmailUI

/// The Flagged view across a change of layout shell (the Duo closing or
/// opening, an iPad window crossing the size-class line): the view stays,
/// and the new layout's list reopens the row the old reader had open. Also
/// what the resume session keeps, and how long the list's model lasts.
@MainActor
final class FlaggedViewSwapTests: XCTestCase {
    private var windows: FlaggedWindows!
    private var coordinator: NavStateCoordinator { windows.coordinator }
    private var inbox: Folder { windows.inbox }
    private var archive: Folder { windows.archive }
    private var message: FlaggedRow { windows.message }
    private var article: FlaggedRow { windows.article }

    override func setUp() async throws {
        try await super.setUp()
        windows = try FlaggedWindows()
    }

    override func tearDown() async throws {
        windows.tearDown()
        try await super.tearDown()
    }

    private func makeNavigator(stored: AppRoute? = nil, seed: ResumeSession.Section = .mail) -> SceneNavigator {
        windows.makeNavigator(stored: stored, seed: seed)
    }

    private func wideWindow(stored: AppRoute? = nil) async -> (navigator: SceneNavigator, tree: UUID) {
        await windows.wideWindow(stored: stored)
    }

    // MARK: A change of layout shell

    /// The Duo closing, or an iPad window narrowing: the tab layout's Mail
    /// stack takes the view over on its list, and the list reopens the row
    /// the split's reader had open.
    func testNarrowingKeepsTheViewAndReopensItsRow() async throws {
        let (navigator, wide) = await wideWindow()
        navigator.showFlagged(from: wide, door: .split)
        navigator.selectFlaggedItem(article, from: wide, door: .split)

        let stack = UUID()
        await navigator.mailTreeAppeared(stack, isWide: false, startsOnFolderList: true)

        XCTAssertTrue(navigator.flaggedIsOpen(in: stack, door: .mail))
        XCTAssertNil(
            navigator.flaggedItem(in: stack, door: .mail), "a list and its reader never arrive together (#1664)"
        )
        XCTAssertEqual(navigator.flaggedColumn(in: stack, door: .mail), .content)
        XCTAssertFalse(navigator.flaggedIsOpen(in: wide, door: .split), "the tree being torn down sees nothing")
        XCTAssertNil(navigator.takeParkedFlaggedItem(in: wide, door: .split), "nor takes what is parked")
        XCTAssertEqual(navigator.route.smartItem?.ref, article.ref, "the window is where it was")

        XCTAssertEqual(navigator.takeParkedFlaggedItem(in: stack, door: .mail), .row(article))
        navigator.selectFlaggedItem(article, from: stack, door: .mail)

        XCTAssertEqual(navigator.flaggedItem(in: stack, door: .mail), article)
        XCTAssertEqual(navigator.flaggedColumn(in: stack, door: .mail), .detail)
    }

    /// The other way: the Duo opening with a message open from the view in
    /// the Mail tab.
    func testWideningKeepsTheViewAndReopensItsRow() async throws {
        let tabs = await windows.tabWindow()
        let navigator = tabs.navigator
        let stack = tabs.mail
        navigator.showFlagged(from: stack, door: .mail)
        navigator.selectFlaggedItem(message, from: stack, door: .mail)

        let wide = UUID()
        await navigator.mailTreeAppeared(wide, isWide: true)

        XCTAssertTrue(navigator.flaggedIsOpen(in: wide, door: .split))
        XCTAssertNil(navigator.flaggedItem(in: wide, door: .split))
        XCTAssertEqual(navigator.takeParkedFlaggedItem(in: wide, door: .split), .row(message))
        navigator.selectFlaggedItem(message, from: wide, door: .split)
        XCTAssertEqual(navigator.flaggedItem(in: wide, door: .split), message)
    }

    /// The view open in the Feeds tab, with the Feeds tab in front, is over
    /// the split when the window widens.
    func testWideningFromTheFeedsTabsDoorShowsItOverTheSplit() async throws {
        let tabs = await windows.tabWindow()
        let navigator = tabs.navigator
        let feeds = tabs.feeds
        navigator.showTab(.feeds)
        navigator.showFlagged(from: feeds, door: .feeds)
        navigator.selectFlaggedItem(article, from: feeds, door: .feeds)

        let wide = UUID()
        await navigator.mailTreeAppeared(wide, isWide: true)

        XCTAssertTrue(navigator.flaggedIsOpen(in: wide, door: .split))
        XCTAssertEqual(navigator.takeParkedFlaggedItem(in: wide, door: .split), .row(article))
    }

    /// The view open in the Mail tab while the Feeds tab is in front is not
    /// what the window was showing: the split opens on feeds, and the view
    /// keeps its place in the Mail tab for the way back.
    func testWideningWithTheOtherTabInFrontLeavesTheViewInItsTab() async throws {
        let tabs = await windows.tabWindow()
        let navigator = tabs.navigator
        let stack = tabs.mail
        navigator.showFlagged(from: stack, door: .mail)
        navigator.showTab(.feeds)
        navigator.selectFeedScope(.all)

        let wide = UUID()
        await navigator.mailTreeAppeared(wide, isWide: true)

        XCTAssertTrue(navigator.splitShowsFeeds)
        XCTAssertFalse(navigator.flaggedIsOpen(in: wide, door: .split))
        XCTAssertEqual(navigator.flaggedPlace.state.door, .mail)
    }

    /// A pick in the split is where a swap to the tab layout opens, as a
    /// folder pick is: a utility tab left behind gives way to the view's.
    func testThePickInTheSplitMovesTheTabTheNarrowLayoutOpensOn() async throws {
        let (navigator, tree) = await wideWindow()
        navigator.showTab(.settings)

        navigator.showFlagged(from: tree, door: .split)

        XCTAssertEqual(navigator.compactTab, .mail)
    }

    /// A swap with the window off the view parks nothing and opens nothing.
    func testASwapOffTheViewOpensNothing() async throws {
        let (navigator, _) = await wideWindow()

        let stack = UUID()
        await navigator.mailTreeAppeared(stack, isWide: false, startsOnFolderList: true)

        XCTAssertFalse(navigator.flaggedOccupies(stack, door: .mail))
        XCTAssertNil(navigator.takeParkedFlaggedItem(in: stack, door: .mail))
    }

    // MARK: The resume session

    /// What another device, or a new window, picks up from: the open row's
    /// own place, since the session has no place for the view.
    func testAnOpenMessageIsRecordedInItsOwnFolder() async throws {
        let (navigator, tree) = await wideWindow()
        navigator.showFlagged(from: tree, door: .split)

        navigator.selectFlaggedItem(message, from: tree, door: .split)

        XCTAssertEqual(coordinator.session.section, .mail)
        XCTAssertEqual(coordinator.session.folder, "Lists")
        XCTAssertEqual(coordinator.session.uid, 4)
    }

    func testAnOpenArticleIsRecordedInItsOwnFeedsList() async throws {
        let (navigator, tree) = await wideWindow()
        navigator.showFlagged(from: tree, door: .split)

        navigator.selectFlaggedItem(article, from: tree, door: .split)

        XCTAssertEqual(coordinator.session.section, .feeds)
        XCTAssertEqual(coordinator.session.feedScope, .subscription("s"))
        XCTAssertEqual(coordinator.session.feedItemSortKey, "a")
    }

    func testLeavingTheViewPutsTheSessionBackOnTheFolderBeneath() async throws {
        let (navigator, tree) = await wideWindow()
        navigator.showFlagged(from: tree, door: .split)
        navigator.selectFlaggedItem(article, from: tree, door: .split)

        navigator.selectFlaggedItem(nil, from: tree, door: .split)

        XCTAssertEqual(coordinator.session.section, .mail)
        XCTAssertEqual(coordinator.session.folder, "INBOX")
        XCTAssertFalse(coordinator.session.hasMessage)
    }

    /// Back from the view with a row still open, on a collapsed stack: the
    /// visit ends, and the session is the folder beneath's again.
    func testBackingOutOfTheViewPutsTheSessionBackToo() async throws {
        let tabs = await windows.tabWindow()
        let navigator = tabs.navigator
        navigator.selectFolder(inbox)
        navigator.setCompactColumn(.sidebar, isSearching: false, from: tabs.mail)
        navigator.showFlagged(from: tabs.mail, door: .mail)
        navigator.selectFlaggedItem(message, from: tabs.mail, door: .mail)
        XCTAssertEqual(coordinator.session.folder, "Lists")

        XCTAssertTrue(navigator.setFlaggedColumn(.sidebar, from: tabs.mail, door: .mail))

        XCTAssertEqual(coordinator.session.folder, "INBOX")
        XCTAssertFalse(coordinator.session.hasMessage)
    }

    // MARK: The window's list model

    func testOneModelLastsTheVisitAndTheNextVisitGetsAnother() async throws {
        let (navigator, tree) = await wideWindow()
        let client = try TestFixtures.makeClient(imap: FakeImapClient())
        let preferences = Preferences(store: InMemoryPreferenceStore())
        let mailStore = AppState().mailStore
        func model() -> FlaggedListViewModel {
            navigator.flaggedList(client: client, preferences: preferences, mailStore: mailStore)
        }
        navigator.showFlagged(from: tree, door: .split)
        let first = model()

        navigator.selectFlaggedItem(article, from: tree, door: .split)
        XCTAssertTrue(model() === first, "a reader opening is the same visit")
        let stack = UUID()
        await navigator.mailTreeAppeared(stack, isWide: false, startsOnFolderList: true)
        XCTAssertTrue(model() === first, "so is a change of layout shell")

        navigator.selectFolder(archive)
        navigator.showFlagged(from: stack, door: .mail)
        XCTAssertFalse(model() === first, "leaving ended the visit: its rows and its pick went")
    }
}

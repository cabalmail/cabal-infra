import XCTest
import SwiftUI
import CabalmailKit
@testable import CabalmailUI

/// The Flagged view in a real window's `SceneNavigator`: its doors, what
/// closes it, what the route keeps, and a restore from a stored route.
/// `FlaggedViewSwapTests` has the change of layout shell.
@MainActor
final class FlaggedViewNavigationTests: XCTestCase {
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

    // MARK: The wide layouts' one entry

    func testTheSidebarEntryOpensTheViewOverTheFolder() async throws {
        let (navigator, tree) = await wideWindow()
        XCTAssertFalse(navigator.flaggedIsOpen(in: tree, door: .split))

        navigator.showFlagged(from: tree, door: .split)

        XCTAssertTrue(navigator.flaggedIsOpen(in: tree, door: .split))
        XCTAssertTrue(navigator.flaggedIsInFront)
        XCTAssertEqual(navigator.selectedFolder?.path, "INBOX", "the folder keeps its place beneath")
        XCTAssertEqual(navigator.route.smartView, .flagged)
        XCTAssertEqual(navigator.route.smartDoor, .mail)
        XCTAssertEqual(navigator.route.mail.folderPath, "INBOX")
    }

    func testAFolderPickClosesIt_EvenThePickOfTheFolderBeneath() async throws {
        for picked in [archive, inbox] {
            let (navigator, tree) = await wideWindow()
            navigator.showFlagged(from: tree, door: .split)
            navigator.selectFlaggedItem(message, from: tree, door: .split)

            navigator.selectFolder(picked)

            XCTAssertFalse(navigator.flaggedIsOpen(in: tree, door: .split), picked.path)
            XCTAssertNil(navigator.flaggedItem(in: tree, door: .split))
            XCTAssertNil(navigator.route.smartView)
            XCTAssertNil(navigator.route.smartDoor)
            XCTAssertNil(navigator.route.smartItem)
            XCTAssertEqual(navigator.selectedFolder?.path, picked.path)
        }
    }

    func testAFeedPickClosesIt() async throws {
        let (navigator, tree) = await wideWindow()
        navigator.showFlagged(from: tree, door: .split)

        navigator.showFeeds(.all)

        XCTAssertFalse(navigator.flaggedIsOpen(in: tree, door: .split))
        XCTAssertTrue(navigator.splitShowsFeeds)
        XCTAssertNil(navigator.route.smartView)
    }

    func testTheSidebarClearingItsSelectionLeavesItOpen() async throws {
        let (navigator, tree) = await wideWindow()
        navigator.showFlagged(from: tree, door: .split)

        navigator.selectFolder(nil)

        XCTAssertTrue(navigator.flaggedIsOpen(in: tree, door: .split))
    }

    func testANavigationToAMessageClosesIt() async throws {
        let (navigator, tree) = await wideWindow()
        navigator.showFlagged(from: tree, door: .split)

        navigator.navigate(to: NavState(folder: "Archive", messageID: nil, uid: 9, clientID: "other"))

        XCTAssertFalse(navigator.flaggedIsOpen(in: tree, door: .split))
        XCTAssertEqual(navigator.selectedFolder?.path, "Archive")
    }

    func testEachVisitIsCountedSoItsListIsBuiltAfresh() async throws {
        let (navigator, tree) = await wideWindow()

        navigator.showFlagged(from: tree, door: .split)
        let first = navigator.flaggedPlace.state.visit
        navigator.showFlagged(from: tree, door: .split)
        XCTAssertEqual(navigator.flaggedPlace.state.visit, first, "the entry picked again is the same visit")

        navigator.selectFolder(archive)
        navigator.showFlagged(from: tree, door: .split)
        XCTAssertEqual(navigator.flaggedPlace.state.visit, first + 1)
    }

    // MARK: The tab layouts' two doors

    func testEachTabOpensTheViewInItsOwnStack() async throws {
        let tabs = await windows.tabWindow()
        let navigator = tabs.navigator
        let mail = tabs.mail
        let feeds = tabs.feeds

        navigator.showFlagged(from: mail, door: .mail)

        XCTAssertTrue(navigator.flaggedIsOpen(in: mail, door: .mail))
        XCTAssertFalse(navigator.flaggedOccupies(feeds, door: .feeds), "the Feeds tab keeps its own place")
        XCTAssertEqual(navigator.flaggedColumn(in: mail, door: .mail), .content)
        XCTAssertNil(navigator.flaggedColumn(in: feeds, door: .feeds))
        XCTAssertEqual(navigator.route.smartDoor, .mail)

        // The other door moves the view to the other tab.
        navigator.showTab(.feeds)
        navigator.showFlagged(from: feeds, door: .feeds)
        XCTAssertTrue(navigator.flaggedIsOpen(in: feeds, door: .feeds))
        XCTAssertFalse(navigator.flaggedOccupies(mail, door: .mail))
        XCTAssertEqual(navigator.route.smartDoor, .feeds)
    }

    func testAPickInTheOtherTabLeavesTheViewOpenInItsOwn() async throws {
        let tabs = await windows.tabWindow()
        let navigator = tabs.navigator
        let mail = tabs.mail
        navigator.showFlagged(from: mail, door: .mail)

        navigator.showTab(.feeds)
        navigator.selectFeedScope(.all)

        XCTAssertTrue(navigator.flaggedIsOpen(in: mail, door: .mail))
        XCTAssertFalse(navigator.flaggedIsInFront, "the Feeds tab is in front, on its own list")

        navigator.showTab(.mail)
        XCTAssertTrue(navigator.flaggedIsInFront)
    }

    func testAFeedPickClosesTheViewOpenedFromTheFeedsTab() async throws {
        let tabs = await windows.tabWindow()
        let navigator = tabs.navigator
        let feeds = tabs.feeds
        navigator.showTab(.feeds)
        navigator.showFlagged(from: feeds, door: .feeds)

        navigator.selectFeedScope(.all)

        XCTAssertFalse(navigator.flaggedOccupies(feeds, door: .feeds))
        XCTAssertEqual(navigator.feeds.scope(in: feeds), .all)
    }

    func testOpeningARowPushesTheReaderAndBackDropsIt() async throws {
        let tabs = await windows.tabWindow()
        let navigator = tabs.navigator
        let mail = tabs.mail
        navigator.showFlagged(from: mail, door: .mail)

        navigator.selectFlaggedItem(article, from: mail, door: .mail)
        XCTAssertEqual(navigator.flaggedColumn(in: mail, door: .mail), .detail)
        XCTAssertEqual(navigator.flaggedItem(in: mail, door: .mail), article)

        XCTAssertTrue(navigator.setFlaggedColumn(.content, from: mail, door: .mail))
        XCTAssertNil(navigator.flaggedItem(in: mail, door: .mail))
        XCTAssertTrue(navigator.flaggedIsOpen(in: mail, door: .mail))
    }

    /// Back from the view's list returns to the folder list. The stack goes
    /// on drawing the view while it slides away; the window is off it.
    func testBackFromTheListReturnsToTheFolderListAndEndsTheVisit() async throws {
        let tabs = await windows.tabWindow()
        let navigator = tabs.navigator
        let mail = tabs.mail
        navigator.showFlagged(from: mail, door: .mail)

        XCTAssertTrue(navigator.setFlaggedColumn(.sidebar, from: mail, door: .mail))

        XCTAssertFalse(navigator.flaggedIsOpen(in: mail, door: .mail))
        XCTAssertTrue(navigator.flaggedOccupies(mail, door: .mail), "still drawn, sliding away")
        XCTAssertEqual(navigator.flaggedColumn(in: mail, door: .mail), .sidebar)
        XCTAssertNil(navigator.route.smartView)
        XCTAssertFalse(navigator.flaggedIsInFront)

        // The stack then moves on to a folder's list: that move is not the
        // view's, and lets go of the door.
        XCTAssertFalse(navigator.setFlaggedColumn(.content, from: mail, door: .mail))
        XCTAssertFalse(navigator.flaggedOccupies(mail, door: .mail))
    }

    /// visionOS: the Folders tab's row opens the view in the Mail tab, as a
    /// folder pick opens the folder there.
    func testPickedOnTheFoldersTabItOpensInTheMailTab() async throws {
        let navigator = makeNavigator()
        let tree = UUID()
        await navigator.mailTreeAppeared(tree, isWide: false)
        navigator.foldersLoaded([inbox, archive])
        navigator.showTab(.folders)

        navigator.showFlagged(from: tree, door: .mail)

        XCTAssertEqual(navigator.compactTab, .mail)
        XCTAssertTrue(navigator.flaggedIsOpen(in: tree, door: .mail))
        XCTAssertTrue(navigator.flaggedIsInFront)
    }

    // MARK: The route, and a restore

    func testTheRouteNamesTheViewItsDoorAndItsOpenRow() async throws {
        let (navigator, tree) = await wideWindow()
        navigator.showFlagged(from: tree, door: .split)

        navigator.selectFlaggedItem(article, from: tree, door: .split)
        XCTAssertEqual(navigator.route.smartItem?.ref, .feed(feedID: "f", sortKey: "a"))
        XCTAssertEqual(navigator.route.openItem, .feed(feedID: "f", sortKey: "a"))

        navigator.selectFlaggedItem(message, from: tree, door: .split)
        XCTAssertEqual(navigator.route.smartItem?.ref, .mail(MessageRef(folder: "Lists", uid: 4)))
        XCTAssertEqual(navigator.route.smartItem?.messageID, "<four@example.com>")
        XCTAssertNil(navigator.route.mail.message, "the folder beneath has no message open")

        navigator.selectFlaggedItem(nil, from: tree, door: .split)
        XCTAssertEqual(navigator.route.smartView, .flagged)
        XCTAssertNil(navigator.route.smartItem)
    }

    /// A window the system restores, stored on the view with an article
    /// open: it comes back on the view, and the article waits for the list
    /// to open it once its rows have loaded.
    func testAWindowStoredOnTheViewWithAnArticleOpenRestoresThere() async throws {
        let (source, tree) = await wideWindow()
        source.showFlagged(from: tree, door: .split)
        source.selectFlaggedItem(article, from: tree, door: .split)
        let stored = try JSONDecoder().decode(AppRoute.self, from: JSONEncoder().encode(source.route))

        let (restored, newTree) = await wideWindow(stored: stored)

        XCTAssertTrue(restored.flaggedIsOpen(in: newTree, door: .split))
        XCTAssertNil(restored.flaggedItem(in: newTree, door: .split), "not before its list has appeared")
        XCTAssertEqual(restored.selectedFolder?.path, "INBOX", "the folder landed beneath as ever")
        XCTAssertEqual(restored.route.smartView, .flagged)
        XCTAssertEqual(
            restored.takeParkedFlaggedItem(in: newTree, door: .split), .ref(.feed(feedID: "f", sortKey: "a"))
        )
        XCTAssertNil(restored.takeParkedFlaggedItem(in: newTree, door: .split), "once")

        // The list found the row and opened it.
        restored.selectFlaggedItem(article, from: newTree, door: .split)
        XCTAssertEqual(restored.flaggedItem(in: newTree, door: .split), article)
    }

    func testAWindowStoredOnTheViewWithAMessageOpenRestoresThere() async throws {
        var stored = AppRoute(section: .mail)
        stored.mail = AppRoute.Mail(folderPath: "Archive")
        stored.smartView = .flagged
        stored.smartDoor = .mail
        stored.smartItem = AppRoute.SmartItem(
            .mail(MessageRef(folder: "Lists", uid: 4, messageId: "<four@example.com>"))
        )

        let (restored, tree) = await wideWindow(stored: stored)

        XCTAssertTrue(restored.flaggedIsOpen(in: tree, door: .split))
        XCTAssertEqual(restored.selectedFolder?.path, "Archive")
        XCTAssertEqual(
            restored.takeParkedFlaggedItem(in: tree, door: .split), .ref(.mail(MessageRef(folder: "Lists", uid: 4)))
        )
    }

    /// The view open in the Mail tab while the Feeds tab was in front: the
    /// stored door, not the section, says which stack it comes back in.
    func testAStoredDoorIsTheStackTheViewComesBackIn() async throws {
        var stored = AppRoute(section: .feeds)
        stored.smartView = .flagged
        stored.smartDoor = .mail
        let navigator = makeNavigator(stored: stored, seed: .feeds)
        let mail = UUID()
        let feeds = UUID()
        await navigator.mailTreeAppeared(mail, isWide: false, startsOnFolderList: true)
        await navigator.feedTreeAppeared(feeds)

        XCTAssertTrue(navigator.flaggedIsOpen(in: mail, door: .mail))
        XCTAssertFalse(navigator.flaggedOccupies(feeds, door: .feeds))
        XCTAssertFalse(navigator.flaggedIsInFront, "the Feeds tab is in front")
    }

    /// A route that names the view and no door (a route another build
    /// stored) opens it in the window's section.
    func testAStoredViewWithNoDoorOpensInTheWindowsSection() async throws {
        var stored = AppRoute(section: .feeds)
        stored.smartView = .flagged
        let navigator = makeNavigator(stored: stored, seed: .feeds)
        let feeds = UUID()
        await navigator.feedTreeAppeared(feeds)

        XCTAssertTrue(navigator.flaggedIsOpen(in: feeds, door: .feeds))
    }
}

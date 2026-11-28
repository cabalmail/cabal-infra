import XCTest
import SwiftUI
import CabalmailKit
@testable import CabalmailUI

/// What a window lands beneath the Flagged view when it has no folder of
/// its own there: a view opened from the Mail tab's folder list, then
/// carried to the split by a change of layout, or restored by a launch.
///
/// The landing takes the folder from the resume session, and the session
/// names the view's open message as the one open in that folder, since that
/// is where another device should resume. Scheduled for the folder's list
/// as well, the message stayed parked beneath the view, which carries its
/// own row across, and opened in the folder once the view was left: by a
/// sidebar pick while wide, or after the round trip and two Backs (#2577).
@MainActor
final class FlaggedViewLandingTests: XCTestCase {
    private var windows: FlaggedWindows!
    private var inbox: Folder { windows.inbox }

    /// A flagged message that lives in INBOX.
    private let message = FlaggedRow.mail(
        Envelope(uid: 7, messageId: "<seven@example.com>", subject: "m7", from: [], flags: [.flagged], folder: "INBOX"),
        MessageRef(folder: "INBOX", uid: 7, messageId: "<seven@example.com>")
    )

    override func setUp() async throws {
        try await super.setUp()
        windows = try FlaggedWindows()
    }

    override func tearDown() async throws {
        windows.tearDown()
        try await super.tearDown()
    }

    /// The tab layout, the Mail tab on its folder list with no folder
    /// open, the view opened from it and the message opened in the view.
    private func messageOpenedInTheTab() async -> FlaggedWindows.Tabs {
        let tabs = await windows.tabWindow()
        XCTAssertNil(tabs.navigator.folder(in: tabs.mail), "the view opens over no folder")
        tabs.navigator.showFlagged(from: tabs.mail, door: .mail)
        tabs.navigator.selectFlaggedItem(message, from: tabs.mail, door: .mail)
        XCTAssertTrue(windows.coordinator.session.hasMessage, "the session names the view's open message")
        return tabs
    }

    /// The window widens: the split's tree takes it over, and the view's
    /// list reopens the row it was carrying.
    private func widen(_ navigator: SceneNavigator) async -> UUID {
        let wide = UUID()
        await navigator.mailTreeAppeared(wide, isWide: true)
        if case .row(let row)? = navigator.takeParkedFlaggedItem(in: wide, door: .split) {
            navigator.selectFlaggedItem(row, from: wide, door: .split)
        }
        return wide
    }

    /// The window narrows: the Mail tab's stack takes it over, the same way.
    private func narrow(_ navigator: SceneNavigator) async -> UUID {
        let stack = UUID()
        await navigator.mailTreeAppeared(stack, isWide: false, startsOnFolderList: true)
        if case .row(let row)? = navigator.takeParkedFlaggedItem(in: stack, door: .mail) {
            navigator.selectFlaggedItem(row, from: stack, door: .mail)
        }
        return stack
    }

    // MARK: A change of layout

    func testWideningSchedulesNoMessageForTheFolderBeneathTheView() async throws {
        let navigator = await messageOpenedInTheTab().navigator

        let wide = await widen(navigator)

        XCTAssertEqual(navigator.flaggedItem(in: wide, door: .split), message, "the view carries its own row")
        XCTAssertEqual(navigator.folder(in: wide)?.path, "INBOX", "the split still has a folder beneath the view")
        XCTAssertNil(navigator.restores.pendingRestore, "and nothing waits for that folder's list to open")
        XCTAssertNil(navigator.route.mail.message)
    }

    /// The first of the issue's two leaving orders: the view left by a
    /// sidebar pick while the window is still wide.
    func testAFolderPickedAfterWideningOpensNoMessage() async throws {
        let navigator = await messageOpenedInTheTab().navigator
        let wide = await widen(navigator)

        navigator.selectFolder(inbox)

        XCTAssertFalse(navigator.flaggedIsOpen(in: wide, door: .split))
        XCTAssertEqual(navigator.folder(in: wide), inbox)
        XCTAssertNil(navigator.restores.pendingRestore, "INBOX's list has no message to open")
        XCTAssertNil(navigator.envelope(in: wide))
        XCTAssertFalse(windows.coordinator.session.hasMessage)
    }

    /// The second: narrowed again, Back to the view's list, Back to the
    /// folder list, then widened.
    func testTheRoundTripThenBackingOutThenWideningOpensNoMessage() async throws {
        let navigator = await messageOpenedInTheTab().navigator
        _ = await widen(navigator)
        let stack = await narrow(navigator)
        XCTAssertEqual(navigator.flaggedItem(in: stack, door: .mail), message)

        XCTAssertTrue(navigator.setFlaggedColumn(.content, from: stack, door: .mail))
        XCTAssertTrue(navigator.setFlaggedColumn(.sidebar, from: stack, door: .mail))
        XCTAssertNil(navigator.folder(in: stack), "on the folder list, the visit over")
        let wide = await widen(navigator)

        XCTAssertEqual(navigator.folder(in: wide)?.path, "INBOX")
        XCTAssertNil(navigator.restores.pendingRestore)
        XCTAssertNil(navigator.envelope(in: wide))
        XCTAssertFalse(navigator.flaggedIsOpen(in: wide, door: .split))
    }

    /// The article case, which was clean before the fix and stays so: an
    /// article opened from the Feeds tab's row and carried to the split
    /// leaves nothing waiting for a folder's list or a feed's, and a folder
    /// picked then has nothing open.
    func testAnArticleCarriedToTheSplitLeavesNothingWaitingBeneathIt() async throws {
        let tabs = await windows.tabWindow()
        let navigator = tabs.navigator
        navigator.showTab(.feeds)
        navigator.showFlagged(from: tabs.feeds, door: .feeds)
        navigator.selectFlaggedItem(windows.article, from: tabs.feeds, door: .feeds)

        let wide = await widen(navigator)

        XCTAssertEqual(navigator.flaggedItem(in: wide, door: .split), windows.article)
        XCTAssertNil(navigator.restores.pendingRestore)
        XCTAssertNil(navigator.restores.pendingFeedRestore)

        navigator.selectFolder(inbox)

        XCTAssertNil(navigator.restores.pendingRestore)
        XCTAssertNil(navigator.envelope(in: wide))
    }

    // MARK: A launch

    /// A window the system restores on the view with its message open, in
    /// a session that names that message: the same landing, the same rule.
    func testAWindowRestoredOnTheViewSchedulesNoMessageForTheFolderBeneath() async throws {
        let first = await messageOpenedInTheTab().navigator
        let stored = first.route
        XCTAssertEqual(stored.smartView, .flagged)
        XCTAssertNil(stored.mail.folderPath)

        let restored = windows.makeNavigator(stored: stored)
        let wide = UUID()
        await restored.mailTreeAppeared(wide, isWide: true)

        XCTAssertTrue(restored.flaggedIsOpen(in: wide, door: .split))
        XCTAssertEqual(restored.takeParkedFlaggedItem(in: wide, door: .split), .ref(message.ref))
        XCTAssertEqual(restored.folder(in: wide)?.path, "INBOX")
        XCTAssertNil(restored.restores.pendingRestore)
    }

    // MARK: Which message the view holds

    /// A route on the view with `message` open in it.
    private var onTheView: AppRoute {
        var route = AppRoute(section: .mail)
        route.smartView = .flagged
        route.smartItem = AppRoute.SmartItem(message.ref)
        return route
    }

    /// A restore of the message those name, as a landing would schedule it.
    private func restore(_ folder: String, messageID: String? = nil, uid: UInt32? = nil) -> NavState {
        NavState(folder: folder, messageID: messageID, uid: uid, clientID: "this-install")
    }

    func testTheViewHoldsTheMessageItHasOpenByMessageID() {
        let route = onTheView
        // The same message under another number: moved and back, as a
        // parked restore is matched.
        XCTAssertTrue(route.smartViewHolds(restore("INBOX", messageID: "<seven@example.com>", uid: 99)))
        XCTAssertFalse(
            route.smartViewHolds(restore("INBOX", messageID: "<eight@example.com>", uid: 7)),
            "another message that took its number"
        )
    }

    func testWithNoMessageIDOnOneSideTheNumberDecides() {
        let route = onTheView
        XCTAssertTrue(route.smartViewHolds(restore("INBOX", uid: 7)))
        XCTAssertFalse(route.smartViewHolds(restore("INBOX", uid: 8)))
        XCTAssertFalse(route.smartViewHolds(restore("INBOX")), "a restore that names no message")
    }

    func testTheViewHoldsNoMessageOfAnotherFolderNorAnyWhileItIsNotUp() {
        var route = onTheView
        XCTAssertFalse(
            route.smartViewHolds(restore("Archive", messageID: "<seven@example.com>", uid: 7)),
            "the same number in another folder is another message"
        )
        route.smartView = nil
        XCTAssertFalse(route.smartViewHolds(restore("INBOX", messageID: "<seven@example.com>", uid: 7)))

        var article = AppRoute(section: .feeds)
        article.smartView = .flagged
        article.smartItem = AppRoute.SmartItem(.feed(feedID: "f", sortKey: "a"))
        XCTAssertFalse(article.smartViewHolds(restore("INBOX", uid: 7)), "an open article is no message")
    }

    func testALandingOnTheFolderAloneKeepsEverythingButTheMessage() throws {
        let anchor = try XCTUnwrap(ListAnchor(folderPath: "INBOX", messageID: nil, uid: 3, index: 12))
        let landing = NavStateCoordinator.MailLaunchTarget(
            folderPath: "INBOX", messageRestore: restore("INBOX", uid: 7), listAnchor: anchor, isFallback: true
        )

        let alone = landing.folderAlone

        XCTAssertNil(alone.messageRestore)
        XCTAssertEqual(alone.folderPath, "INBOX")
        XCTAssertEqual(alone.listAnchor, anchor)
        XCTAssertTrue(alone.isFallback)
    }

    // MARK: Off the view, the landing is what it was

    /// The control: a window that is not on the view and has no folder of
    /// its own still lands on the session's folder with its open message
    /// scheduled for the list.
    func testWithNoViewTheSessionsOpenMessageIsStillScheduledForItsFolder() async throws {
        _ = await messageOpenedInTheTab()

        let other = windows.makeNavigator()
        let wide = UUID()
        await other.mailTreeAppeared(wide, isWide: true)

        XCTAssertEqual(other.folder(in: wide)?.path, "INBOX")
        XCTAssertEqual(other.restores.pendingRestore?.folderPath, "INBOX")
        XCTAssertEqual(other.restores.pendingRestore?.uid, 7)
    }
}

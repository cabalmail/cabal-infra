import XCTest
import CabalmailKit
@testable import CabalmailUI

/// One main window's menu commands (`WindowCommands`, workstream 3.1): each
/// command has its own count on its own window's object, the menus read the
/// availability of the surface in front, and only the tab in front answers.
@MainActor
final class WindowCommandsTests: XCTestCase {

    private func makeWindow(wide: Bool = false, tab: CompactTab = .mail) -> WindowCommands {
        let navigator = SceneNavigator(coordinator: { nil }, hasClient: { false }, seed: .mail)
        navigator.layoutIsWide = wide
        navigator.showTab(tab)
        return WindowCommands(navigator: navigator)
    }

    // Each command's own count, and two windows' objects, are pinned in
    // `CommandTickCharacterizationTests` for every command.

    // MARK: - The surface in front

    func testTheWideLayoutsHaveOneSurfaceAndTheTabLayoutsTheTabInFront() {
        XCTAssertEqual(makeWindow(wide: true, tab: .search).front, .window)
        XCTAssertEqual(makeWindow(wide: false, tab: .search).front, .tab(.search))
        XCTAssertEqual(FrontSurfacePolicy.front(layoutIsWide: false, compactTab: .feeds), .tab(.feeds))
    }

    func testASurfaceInNoTabAlwaysAnswers() {
        for front in [CommandSurface.window, .tab(.mail), .tab(.search)] {
            XCTAssertTrue(FrontSurfacePolicy.answers(tab: nil, front: front))
        }
    }

    func testATabAnswersOnlyWhileItIsInFront() {
        XCTAssertTrue(FrontSurfacePolicy.answers(tab: .mail, front: .tab(.mail)))
        XCTAssertFalse(FrontSurfacePolicy.answers(tab: .mail, front: .tab(.search)), "a visited tab stays mounted")
        XCTAssertFalse(FrontSurfacePolicy.answers(tab: .search, front: .tab(.mail)))
        XCTAssertFalse(FrontSurfacePolicy.answers(tab: .mail, front: .window), "a tab tree being swapped out")
    }

    func testTheFrontTabFollowsTheTabBar() {
        let window = makeWindow(tab: .mail)
        XCTAssertTrue(window.answers(in: .mail))
        XCTAssertFalse(window.answers(in: .search))

        window.navigator.showTab(.search)

        XCTAssertFalse(window.answers(in: .mail))
        XCTAssertTrue(window.answers(in: .search))
        XCTAssertTrue(window.answers(in: nil))
    }

    // MARK: - Availability

    func testTheMessageMenuFollowsTheTabInFront() {
        let window = makeWindow(tab: .mail)
        let openMessage = MessageMenuAvailability(selectedCount: 0, hasOpenMessage: true)
        let searchSelection = MessageMenuAvailability(selectedCount: 3, hasOpenMessage: false)
        window.report(openMessage, in: .mail, by: UUID())
        window.report(searchSelection, in: .search, by: UUID())
        XCTAssertEqual(window.messageMenu, openMessage)

        window.navigator.showTab(.search)
        XCTAssertEqual(window.messageMenu, searchSelection, "the Search tab's own report")

        window.navigator.showTab(.settings)
        XCTAssertEqual(window.messageMenu, MessageMenuAvailability.none, "nothing in Settings to act on")
    }

    func testTheWideLayoutReadsTheWindowsOwnReport() {
        let window = makeWindow(wide: true)
        let report = MessageMenuAvailability(selectedCount: 1, hasOpenMessage: true)
        window.report(report, in: nil, by: UUID())
        window.report(MessageMenuAvailability.none, in: .mail, by: UUID())

        XCTAssertEqual(window.messageMenu, report)
    }

    func testTwoWindowsKeepTheirOwnAvailability() {
        let windowA = makeWindow(wide: true)
        let windowB = makeWindow(wide: true)
        windowA.report(MessageMenuAvailability(selectedCount: 2, hasOpenMessage: false), in: nil, by: UUID())

        XCTAssertTrue(windowA.messageMenu.canActOnSelection)
        XCTAssertEqual(windowB.messageMenu, MessageMenuAvailability.none)
    }

    /// A layout swap or a re-keyed view brings its new reporter on before
    /// the old one leaves; the old one's withdrawal must not clear the new
    /// report.
    func testOnlyTheReporterThatWroteAReportClearsIt() {
        let window = makeWindow(wide: true)
        let old = UUID()
        let new = UUID()
        window.report(MessageMenuAvailability(selectedCount: 1, hasOpenMessage: true), in: nil, by: old)
        window.report(MessageMenuAvailability(selectedCount: 0, hasOpenMessage: true), in: nil, by: new)

        window.withdrawMessageReport(in: nil, by: old)
        XCTAssertTrue(window.messageMenu.canReply, "the new reporter's report stands")

        window.withdrawMessageReport(in: nil, by: new)
        XCTAssertEqual(window.messageMenu, MessageMenuAvailability.none)
    }

    func testTheFeedsMenuReadsTheSurfaceInFrontToo() {
        let window = makeWindow(tab: .feeds)
        let item = FeedMenuAvailability(selectedCount: 1, hasOpenItem: true, hasScope: true)
        let reporter = UUID()
        window.report(item, in: .feeds, by: reporter)
        XCTAssertEqual(window.feedMenu, item)

        window.navigator.showTab(.mail)
        XCTAssertEqual(window.feedMenu, FeedMenuAvailability.none)

        window.navigator.showTab(.feeds)
        window.withdrawFeedReport(in: .feeds, by: reporter)
        XCTAssertEqual(window.feedMenu, FeedMenuAvailability.none)
    }

    // MARK: - The shared chords

    func testTheTabInFrontDecidesTheSectionOnTheTabLayouts() {
        let window = makeWindow(tab: .feeds)
        window.reportedSection = .mail
        XCTAssertEqual(window.activeSection, .feeds)

        window.navigator.showTab(.search)
        XCTAssertEqual(window.activeSection, .mail, "search results are mail")
        window.navigator.showTab(.mail)
        XCTAssertEqual(window.activeSection, .mail)
    }

    func testTheSplitReportsTheSectionOnTheWideLayouts() {
        let window = makeWindow(wide: true, tab: .mail)
        XCTAssertEqual(window.activeSection, .mail)

        window.reportedSection = .feeds

        XCTAssertEqual(window.activeSection, .feeds)
    }

    /// The Search tab in front holds the Message menu's ⌘T even when the
    /// Feeds tab was the last section shown.
    func testTheSearchTabHoldsTheMessageMenusChords() {
        let window = makeWindow(tab: .feeds)
        window.report(MessageMenuAvailability(selectedCount: 0, hasOpenMessage: true), in: .search, by: UUID())
        window.report(FeedMenuAvailability(selectedCount: 1, hasOpenItem: true, hasScope: true), in: .feeds, by: UUID())
        window.navigator.showTab(.search)

        XCTAssertTrue(SharedChordPolicy.mailItemsLive(window.messageMenu, activeSection: window.activeSection))
        XCTAssertFalse(SharedChordPolicy.feedItemsLive(window.feedMenu, activeSection: window.activeSection))
    }

    // MARK: - The dispose chord

    func testOnlyTheSurfaceInFrontHoldsTheDisposeChord() {
        let window = makeWindow(tab: .mail)
        window.report(MessageMenuAvailability(selectedCount: 2, hasOpenMessage: false), in: .mail, by: UUID())
        window.report(MessageMenuAvailability(selectedCount: 1, hasOpenMessage: true), in: .search, by: UUID())
        XCTAssertEqual(window.disposeChordHost(in: .mail), .list)
        XCTAssertEqual(window.disposeChordHost(in: .search), DisposeChordHost.none, "a tab behind installs nothing")

        window.navigator.showTab(.search)

        XCTAssertEqual(window.disposeChordHost(in: .mail), DisposeChordHost.none)
        XCTAssertEqual(window.disposeChordHost(in: .search), .reader)
    }

    func testEachWindowHoldsItsOwnDisposeChord() {
        let windowA = makeWindow(wide: true)
        let windowB = makeWindow(wide: true)
        windowA.report(MessageMenuAvailability(selectedCount: 1, hasOpenMessage: true), in: nil, by: UUID())
        windowB.report(MessageMenuAvailability(selectedCount: 3, hasOpenMessage: false), in: nil, by: UUID())

        XCTAssertEqual(windowA.disposeChordHost(in: nil), .reader)
        XCTAssertEqual(windowB.disposeChordHost(in: nil), .list)
    }

    // MARK: - The Mailbox menu

    func testEachWindowCountsItsOwnMailSurfaces() {
        let windowA = makeWindow(wide: true)
        let windowB = makeWindow(wide: true)
        windowA.mailbox.surfaceAppeared()
        windowA.mailbox.folderListAppeared("INBOX")

        XCTAssertTrue(windowA.mailbox.canRefresh)
        XCTAssertTrue(windowA.mailbox.canMarkAllRead)
        XCTAssertFalse(windowB.mailbox.canRefresh, "another window's list is not this one's")
        XCTAssertFalse(windowB.mailbox.canMarkAllRead)
    }
}

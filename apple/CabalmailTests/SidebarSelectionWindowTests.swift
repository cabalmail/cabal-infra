import XCTest
import SwiftUI
import CabalmailKit
@testable import CabalmailUI

/// The Mac sidebar's one selection over real windows: each main window's
/// list reads and writes its own `SceneNavigator`, through the two paths a
/// folder pick and a feed pick always took (`selectFolder`, `showFeeds`), so
/// moving through the folders and on into the feeds in one window leaves
/// another window where it was.
@MainActor
final class SidebarSelectionWindowTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var store: ResumeSessionStore!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "SidebarSelectionWindowTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        store = ResumeSessionStore(defaults: defaults)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        try await super.tearDown()
    }

    private let inbox = Folder(path: "INBOX", isSubscribed: true)
    private let archive = Folder(path: "Archive", isSubscribed: true)
    private var folders: [Folder] { [inbox, archive] }

    /// One main window on the wide layout, landed on INBOX, with its
    /// sidebar's list selection wired as the wide shells wire the two
    /// bindings it is made of (`WideMail.sidebarSelection`,
    /// `WideMail.feedSidebarSelection`).
    private struct Window {
        let navigator: SceneNavigator
        let tree: UUID
        let selection: Binding<SidebarSelection?>
    }

    private func makeWindow(_ coordinator: NavStateCoordinator, selectsFeeds: Bool = true) async -> Window {
        let navigator = SceneNavigator(
            coordinator: { coordinator }, hasClient: { true }, seed: .mail,
            feedsLaunchTarget: { _, _ in nil }
        )
        let tree = UUID()
        await navigator.mailTreeAppeared(tree, isWide: true)
        navigator.foldersLoaded(folders)
        let folders = folders
        let selection = SidebarListSelection(selectsFeeds: selectsFeeds).binding(
            folder: Binding(get: { navigator.folder(in: tree) }, set: { navigator.selectFolder($0) }),
            feedScope: Binding(
                get: { navigator.splitShowsFeeds ? navigator.feeds.scope(in: tree) : nil },
                set: { navigator.showFeeds($0) }
            ),
            folders: { folders }
        )
        return Window(navigator: navigator, tree: tree, selection: selection)
    }

    private func makeCoordinator() throws -> NavStateCoordinator {
        store.saveSession(ResumeSession(section: .mail, folder: "INBOX"))
        let client = try TestFixtures.makeClient(imap: FakeImapClient())
        return NavStateCoordinator(client: client, clientID: "this-install", store: store)
    }

    func testAWindowOpensWithItsFolderSelected() async throws {
        let window = await makeWindow(try makeCoordinator())

        XCTAssertEqual(window.selection.wrappedValue, .mailFolder(path: "INBOX"))
    }

    /// The arrow keys' walk: down the folders, on into the feeds, and back.
    /// Each step is one write of the list's selection.
    func testOneSelectionMovesThroughFoldersAndFeeds() async throws {
        let window = await makeWindow(try makeCoordinator())
        let navigator = window.navigator

        window.selection.wrappedValue = .mailFolder(path: "Archive")
        XCTAssertEqual(navigator.selectedFolder, archive)
        XCTAssertEqual(window.selection.wrappedValue, .mailFolder(path: "Archive"))

        window.selection.wrappedValue = .feedScope(.all)
        XCTAssertEqual(window.selection.wrappedValue, .feedScope(.all))
        XCTAssertTrue(navigator.splitShowsFeeds)
        XCTAssertNil(navigator.selectedFolder, "the split shows one medium at a time")
        XCTAssertEqual(navigator.route.section, .feeds)
        XCTAssertEqual(navigator.route.feeds.scope, .all)

        window.selection.wrappedValue = .feedScope(.subscription("s"))
        XCTAssertEqual(window.selection.wrappedValue, .feedScope(.subscription("s")))
        XCTAssertEqual(navigator.route.feeds.scope, .subscription("s"))

        window.selection.wrappedValue = .mailFolder(path: "INBOX")
        XCTAssertEqual(window.selection.wrappedValue, .mailFolder(path: "INBOX"))
        XCTAssertFalse(navigator.splitShowsFeeds)
        XCTAssertEqual(navigator.selectedFolder, inbox)
        XCTAssertEqual(navigator.route.section, .mail)
        XCTAssertNil(navigator.route.feeds.scope, "a folder picked over a feed list closes it")
    }

    /// The control for the walk: where feed rows are buttons, the same
    /// window shows no selected row while it shows a feed list, and a feed
    /// selection reaching the list moves nothing.
    func testTheSameWalkWhereFeedsAreButtons() async throws {
        let window = await makeWindow(try makeCoordinator(), selectsFeeds: false)
        let navigator = window.navigator

        window.selection.wrappedValue = .feedScope(.all)
        XCTAssertFalse(navigator.splitShowsFeeds)
        XCTAssertEqual(window.selection.wrappedValue, .mailFolder(path: "INBOX"))

        navigator.showFeeds(.all)
        XCTAssertNil(window.selection.wrappedValue)
    }

    func testAFeedPickedInOneWindowLeavesAnotherWhereItWas() async throws {
        let coordinator = try makeCoordinator()
        let first = await makeWindow(coordinator)
        let second = await makeWindow(coordinator)
        second.selection.wrappedValue = .mailFolder(path: "Archive")
        let secondRoute = second.navigator.route

        first.selection.wrappedValue = .feedScope(.subscription("s"))

        XCTAssertEqual(first.selection.wrappedValue, .feedScope(.subscription("s")))
        XCTAssertEqual(second.selection.wrappedValue, .mailFolder(path: "Archive"))
        XCTAssertEqual(second.navigator.route, secondRoute)
        XCTAssertFalse(second.navigator.splitShowsFeeds)

        second.selection.wrappedValue = .feedScope(.all)
        first.selection.wrappedValue = .mailFolder(path: "INBOX")

        XCTAssertEqual(second.selection.wrappedValue, .feedScope(.all))
        XCTAssertEqual(first.selection.wrappedValue, .mailFolder(path: "INBOX"))
        XCTAssertEqual(first.navigator.route.section, .mail)
        XCTAssertEqual(second.navigator.route.section, .feeds)
    }

    /// A click on the sidebar's empty space while a feed is open leaves it
    /// open, in the window's own state and not only in the rule.
    func testClearingTheSelectionLeavesTheWindowsFeedOpen() async throws {
        let window = await makeWindow(try makeCoordinator())
        window.selection.wrappedValue = .feedScope(.all)

        window.selection.wrappedValue = nil

        XCTAssertEqual(window.selection.wrappedValue, .feedScope(.all))
        XCTAssertTrue(window.navigator.splitShowsFeeds)
    }
}

import XCTest
import Observation
import CabalmailKit
@testable import CabalmailUI

/// The navigator's side of the window's mail place (`MailNavigationState`):
/// what a write to it tells the views to redraw, and the one clear that no
/// other navigator suite asked for.
///
/// **Redraws.** The folder, the open message and the column are one observed
/// value, so a write to any of them reaches every view that reads one. That
/// is what the three separate properties did for the shells, which read all
/// three. What must not change is that a write which changes nothing redraws
/// nothing: the same message selected again, the column already on screen, a
/// write from a tree a layout swap has replaced. Each is routine (a list
/// re-asserts its selection, a torn-down tree keeps writing for a frame or
/// two), and a redraw on each would rebuild the split inside the very swap
/// the tree gate exists to keep quiet.
@MainActor
final class SceneNavigatorMailPlaceTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var store: ResumeSessionStore!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "SceneNavigatorMailPlaceTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        store = ResumeSessionStore(defaults: defaults)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        try await super.tearDown()
    }

    private let inbox = Folder(path: "INBOX", isSubscribed: true)
    private let archive = Folder(path: "Archive", isSubscribed: true)
    private let message = TestFixtures.makeEnvelope(uid: 9, messageId: "<nine@example.com>")
    private let other = TestFixtures.makeEnvelope(uid: 12, messageId: "<twelve@example.com>")

    /// Whether a tracked read has been told to redraw.
    private final class Redraw: @unchecked Sendable {
        private let lock = NSLock()
        private var asked = false

        var wasAsked: Bool { lock.withLock { asked } }
        func ask() { lock.withLock { asked = true } }
    }

    /// A navigator landed compact on INBOX with `message` open, and the tree
    /// that owns its place.
    private func reading() async throws -> (navigator: SceneNavigator, tree: UUID) {
        let client = try TestFixtures.makeClient(imap: FakeImapClient())
        let coordinator = NavStateCoordinator(client: client, clientID: "this-install", store: store)
        let navigator = SceneNavigator(coordinator: { coordinator }, hasClient: { true }, seed: .mail)
        let tree = UUID()
        await navigator.mailTreeAppeared(tree, isWide: false)
        navigator.foldersLoaded([inbox, archive])
        navigator.selectMessage(message, isSearching: false, from: tree)
        XCTAssertEqual(navigator.envelope(in: tree), message)
        return (navigator, tree)
    }

    // MARK: Redraws

    /// Reads what a shell reads, as a view's body would, and reports whether
    /// `write` asked for that body again.
    private func redraws(
        _ navigator: SceneNavigator, in tree: UUID, after write: () -> Void
    ) -> Bool {
        let redraw = Redraw()
        withObservationTracking {
            _ = navigator.folder(in: tree)
            _ = navigator.envelope(in: tree)
            _ = navigator.compactColumn(in: tree)
        } onChange: {
            redraw.ask()
        }
        write()
        return redraw.wasAsked
    }

    func testAWriteThatChangesThePlaceRedraws() async throws {
        let (navigator, tree) = try await reading()

        XCTAssertTrue(redraws(navigator, in: tree) {
            navigator.selectMessage(other, isSearching: false, from: tree)
        })
        XCTAssertTrue(redraws(navigator, in: tree) {
            navigator.setCompactColumn(.content, isSearching: false, from: tree)
        })
        XCTAssertTrue(redraws(navigator, in: tree) { navigator.selectFolder(archive) })
    }

    func testTheSameMessageFolderOrColumnAgainRedrawsNothing() async throws {
        let (navigator, tree) = try await reading()

        XCTAssertFalse(redraws(navigator, in: tree) {
            navigator.selectMessage(message, isSearching: false, from: tree)
        }, "the list re-asserting its selection redrew the shell")
        XCTAssertFalse(redraws(navigator, in: tree) {
            navigator.setCompactColumn(.detail, isSearching: false, from: tree)
        }, "the column already on screen redrew the shell")
        XCTAssertFalse(redraws(navigator, in: tree) { navigator.selectFolder(inbox) })
        XCTAssertFalse(redraws(navigator, in: tree) { navigator.foldersLoaded([inbox, archive]) })
    }

    // MARK: Clearing mail for a feed

    /// The wide split shows feeds with no mail folder open, and its search
    /// field still searches mail. A result opened from there has no folder
    /// under it, so the folder clearing again does not close it: the feed
    /// pick has to, or the reader keeps the result over the feed.
    func testAFeedPickClosesASearchResultOpenWithNoFolder() async throws {
        let client = try TestFixtures.makeClient(imap: FakeImapClient())
        let coordinator = NavStateCoordinator(client: client, clientID: "this-install", store: store)
        let navigator = SceneNavigator(coordinator: { coordinator }, hasClient: { true }, seed: .mail)
        let tree = UUID()
        await navigator.mailTreeAppeared(tree, isWide: true)
        navigator.foldersLoaded([inbox, archive])
        navigator.showFeeds(.all)
        XCTAssertNil(navigator.folder(in: tree))
        let result = message.inFolder("Archive")
        navigator.selectMessage(result, isSearching: true, from: tree)
        XCTAssertEqual(navigator.envelope(in: tree), result)

        navigator.showFeeds(.subscription("a"))

        XCTAssertNil(navigator.envelope(in: tree), "the search result stayed open over the feed")
        XCTAssertNil(navigator.takeHandedOffSearchResult(), "and would have been handed to the next layout")
    }

    /// A tree a layout swap is tearing down keeps writing for a frame or
    /// two. Its writes are dropped, and dropping them must not redraw the
    /// tree that is taking over.
    func testAWriteFromAReplacedTreeRedrawsNothing() async throws {
        let (navigator, tree) = try await reading()
        let rebuilt = UUID()
        await navigator.mailTreeAppeared(rebuilt, isWide: true)

        XCTAssertFalse(redraws(navigator, in: rebuilt) {
            navigator.selectMessage(nil, isSearching: false, from: tree)
        })
        XCTAssertFalse(redraws(navigator, in: rebuilt) {
            navigator.setCompactColumn(.sidebar, isSearching: false, from: tree)
        })
        XCTAssertEqual(navigator.folder(in: rebuilt), inbox, "and the window is where it was")
    }
}

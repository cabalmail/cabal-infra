import XCTest
import CabalmailKit
@testable import CabalmailUI

/// The hand-off to a tree a layout swap rebuilt, while it waits on the feed
/// store and around the navigations that can land in the middle of it
/// (`SceneNavigator.mailTreeAppeared`). The feed-store lookup is replaced by
/// one the test holds open, so the wait can be observed.
@MainActor
final class SceneNavigatorHandOffTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var store: ResumeSessionStore!

    override func setUp() {
        super.setUp()
        suiteName = "SceneNavigatorHandOffTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        store = ResumeSessionStore(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private let inbox = Folder(path: "INBOX", isSubscribed: true)
    private let archive = Folder(path: "Archive", isSubscribed: true)
    private let message = TestFixtures.makeEnvelope(uid: 9, messageId: "<nine@example.com>")

    /// A feed-store lookup that waits until the test releases it.
    private final class HeldLookup {
        private var entered: CheckedContinuation<Void, Never>?
        private var held: CheckedContinuation<RssItemScope?, Never>?
        private var didEnter = false

        func lookup() async -> RssItemScope? {
            didEnter = true
            entered?.resume()
            entered = nil
            return await withCheckedContinuation { held = $0 }
        }

        func waitUntilEntered() async {
            if didEnter { return }
            await withCheckedContinuation { entered = $0 }
        }

        func release(with scope: RssItemScope?) {
            held?.resume(returning: scope)
            held = nil
        }
    }

    private func makeCoordinator() throws -> NavStateCoordinator {
        let client = try TestFixtures.makeClient(imap: FakeImapClient())
        return NavStateCoordinator(client: client, clientID: "this-install", store: store)
    }

    /// A window that landed compact on INBOX with `message` open, then moved
    /// to the Feeds tab: its next wide tree waits on the feed store.
    private func windowReadingMailThenOnFeeds(
        _ coordinator: NavStateCoordinator, lookup: HeldLookup
    ) async -> (navigator: SceneNavigator, compact: UUID) {
        let navigator = SceneNavigator(
            coordinator: { coordinator }, hasClient: { true }, seed: .mail,
            feedsLaunchTarget: { _ in await lookup.lookup() }
        )
        let compact = UUID()
        _ = await navigator.mailTreeAppeared(compact, isWide: false, showingFeeds: false)
        navigator.foldersLoaded([inbox, archive])
        navigator.selectMessage(message, isSearching: false, from: compact)
        navigator.showTab(.feeds)
        return (navigator, compact)
    }

    /// While a wide tree waits on the feed store, it sees no folder (so no
    /// list mounts early) and the tree it replaces can no longer write.
    func testWhileAHandOffWaitsNeitherTreeMovesTheWindow() async throws {
        let coordinator = try makeCoordinator()
        let lookup = HeldLookup()
        let (navigator, compact) = await windowReadingMailThenOnFeeds(coordinator, lookup: lookup)
        let wide = UUID()

        let handOff = Task { await navigator.mailTreeAppeared(wide, isWide: true, showingFeeds: false) }
        await lookup.waitUntilEntered()

        XCTAssertNil(navigator.folder(in: wide))
        navigator.selectMessage(TestFixtures.makeEnvelope(uid: 12), isSearching: false, from: compact)
        navigator.setCompactColumn(.sidebar, isSearching: false, from: compact)
        XCTAssertEqual(navigator.route.mail.message, MessageRef(folder: "INBOX", uid: 9))
        XCTAssertEqual(coordinator.session.uid, 9)

        lookup.release(with: nil)
        _ = await handOff.value
        XCTAssertEqual(navigator.folder(in: wide), inbox)
        XCTAssertEqual(navigator.compactColumn(in: wide), .content)
        XCTAssertEqual(coordinator.pendingRestore?.uid, 9)
    }

    /// A second swap while the first hand-off waits: the tree it replaced
    /// takes nothing over when its wait ends, even with a scope to open.
    func testATreeReplacedDuringItsHandOffTakesNothingOver() async throws {
        let coordinator = try makeCoordinator()
        let lookup = HeldLookup()
        let (navigator, _) = await windowReadingMailThenOnFeeds(coordinator, lookup: lookup)
        let wide = UUID()
        let handOff = Task { await navigator.mailTreeAppeared(wide, isWide: true, showingFeeds: false) }
        await lookup.waitUntilEntered()

        let compactAgain = UUID()
        _ = await navigator.mailTreeAppeared(compactAgain, isWide: false, showingFeeds: false)
        lookup.release(with: .all)
        let scope = await handOff.value

        XCTAssertNil(scope, "the replaced tree opens no feed scope")
        XCTAssertNil(navigator.folder(in: wide))
        XCTAssertEqual(navigator.folder(in: compactAgain), inbox, "the mail position survives")
        XCTAssertEqual(navigator.route.mail.message, MessageRef(folder: "INBOX", uid: 9))
    }

    /// A wide tree that reopens the session's feed scope clears the mail
    /// side, as a feed pick does, but is not a pick: a utility tab survives.
    func testAWideHandOffIntoFeedsKeepsAUtilityTab() async throws {
        let coordinator = try makeCoordinator()
        let lookup = HeldLookup()
        let (navigator, _) = await windowReadingMailThenOnFeeds(coordinator, lookup: lookup)
        navigator.showTab(.settings)
        let wide = UUID()
        let handOff = Task { await navigator.mailTreeAppeared(wide, isWide: true, showingFeeds: false) }
        await lookup.waitUntilEntered()

        lookup.release(with: .all)
        let scope = await handOff.value

        XCTAssertEqual(scope, .all)
        XCTAssertNil(navigator.selectedFolder)
        XCTAssertEqual(navigator.compactTab, .settings)
    }

    /// The same, when there is no scope to reopen: the split shows mail and
    /// the section moves, but a utility tab still survives.
    func testAWideHandOffFallingThroughToMailKeepsAUtilityTab() async throws {
        let coordinator = try makeCoordinator()
        let lookup = HeldLookup()
        let (navigator, _) = await windowReadingMailThenOnFeeds(coordinator, lookup: lookup)
        navigator.showTab(.settings)
        let handOff = Task { await navigator.mailTreeAppeared(UUID(), isWide: true, showingFeeds: false) }
        await lookup.waitUntilEntered()

        lookup.release(with: nil)
        _ = await handOff.value

        XCTAssertEqual(navigator.route.section, .mail)
        XCTAssertEqual(navigator.compactTab, .settings)
    }

    /// A same-folder navigation names its message in the route, so a swap
    /// before the list applies it re-parks that message, not the one that
    /// was open before.
    func testASwapAfterASameFolderNavigationReParksItsMessage() async throws {
        let coordinator = try makeCoordinator()
        let navigator = SceneNavigator(coordinator: { coordinator }, hasClient: { true }, seed: .mail)
        let compact = UUID()
        _ = await navigator.mailTreeAppeared(compact, isWide: false, showingFeeds: false)
        navigator.foldersLoaded([inbox])
        navigator.selectMessage(message, isSearching: false, from: compact)

        navigator.navigate(to: NavState(folder: "INBOX", messageID: "<four@example.com>", uid: 4, clientID: "push"))
        _ = await navigator.mailTreeAppeared(UUID(), isWide: true, showingFeeds: false)

        XCTAssertEqual(coordinator.pendingRestore?.uid, 4)
        XCTAssertEqual(coordinator.pendingRestore?.messageID, "<four@example.com>")
    }

    /// On the wide layout, opening a different message is a pick: the tab a
    /// swap back opens on follows it to Mail.
    func testOpeningAnotherMessageInTheSplitMovesAUtilityTab() async throws {
        let coordinator = try makeCoordinator()
        let navigator = SceneNavigator(coordinator: { coordinator }, hasClient: { true }, seed: .mail)
        let compact = UUID()
        _ = await navigator.mailTreeAppeared(compact, isWide: false, showingFeeds: false)
        navigator.foldersLoaded([inbox])
        navigator.showTab(.settings)
        let wide = UUID()
        _ = await navigator.mailTreeAppeared(wide, isWide: true, showingFeeds: false)

        navigator.selectMessage(message, isSearching: false, from: wide)

        XCTAssertEqual(navigator.compactTab, .mail)
    }
}

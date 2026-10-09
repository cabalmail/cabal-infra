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

    /// A feed-store lookup that waits until the test releases it. Main
    /// actor throughout, like the navigator that calls it.
    @MainActor
    private final class HeldLookup {
        private var held: CheckedContinuation<RssItemScope?, Never>?

        func lookup() async -> RssItemScope? {
            await withCheckedContinuation { held = $0 }
        }

        /// Fails the test rather than hanging if the lookup is never reached.
        func waitUntilEntered(file: StaticString = #filePath, line: UInt = #line) async throws {
            try await waitUntilOnMainActor(file: file, line: line) { self.held != nil }
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
        await navigator.mailTreeAppeared(compact, isWide: false)
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

        let handOff = Task { await navigator.mailTreeAppeared(wide, isWide: true) }
        try await lookup.waitUntilEntered()

        XCTAssertNil(navigator.folder(in: wide))
        navigator.selectMessage(TestFixtures.makeEnvelope(uid: 12), isSearching: false, from: compact)
        navigator.setCompactColumn(.sidebar, isSearching: false, from: compact)
        navigator.selectMessage(TestFixtures.makeEnvelope(uid: 13), isSearching: false, from: wide)
        XCTAssertEqual(navigator.route.mail.message, MessageRef(folder: "INBOX", uid: 9))
        XCTAssertEqual(coordinator.session.uid, 9)

        lookup.release(with: nil)
        await handOff.value
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
        let handOff = Task { await navigator.mailTreeAppeared(wide, isWide: true) }
        try await lookup.waitUntilEntered()

        let compactAgain = UUID()
        await navigator.mailTreeAppeared(compactAgain, isWide: false)
        lookup.release(with: .all)
        await handOff.value

        XCTAssertNil(navigator.feeds.scope, "the replaced tree opens no feed scope")
        XCTAssertNil(navigator.folder(in: wide))
        XCTAssertEqual(navigator.folder(in: compactAgain), inbox, "the mail position survives")
        XCTAssertEqual(navigator.route.mail.message, MessageRef(folder: "INBOX", uid: 9))
    }

    /// The same with no scope to open: the replaced tree moves neither the
    /// section nor the session to mail behind the compact Feeds tab.
    func testATreeReplacedDuringAHandOffWithNoScopeMovesNothing() async throws {
        let coordinator = try makeCoordinator()
        let lookup = HeldLookup()
        let (navigator, _) = await windowReadingMailThenOnFeeds(coordinator, lookup: lookup)
        let handOff = Task { await navigator.mailTreeAppeared(UUID(), isWide: true) }
        try await lookup.waitUntilEntered()
        await navigator.mailTreeAppeared(UUID(), isWide: false)

        lookup.release(with: nil)
        await handOff.value

        XCTAssertEqual(navigator.route.section, .feeds)
        XCTAssertEqual(coordinator.session.section, .feeds)
    }

    /// A swap back to a compact tab with no mail tree (the Feeds tab here)
    /// during the wait: no tree replaces the wide one, but it was swapped
    /// away, so it takes nothing over — with or without a scope.
    func testATreeSwappedAwayDuringItsHandOffTakesNothingOver() async throws {
        for found in [RssItemScope?.none, .all] {
            let coordinator = try makeCoordinator()
            let lookup = HeldLookup()
            let (navigator, _) = await windowReadingMailThenOnFeeds(coordinator, lookup: lookup)
            let handOff = Task { await navigator.mailTreeAppeared(UUID(), isWide: true) }
            try await lookup.waitUntilEntered()
            navigator.layoutIsWide = false

            lookup.release(with: found)
            await handOff.value

            XCTAssertNil(navigator.feeds.scope)
            XCTAssertEqual(navigator.selectedFolder, inbox, "the mail position survives")
            XCTAssertEqual(navigator.route.section, .feeds)
            XCTAssertEqual(coordinator.session.section, .feeds)
        }
    }

    /// The same for a wide window's first landing: swapped away during the
    /// feed lookup, it does not land on mail behind the compact Feeds tab.
    func testAFirstLandingSwappedAwayDuringItsLookupDoesNotLand() async throws {
        store.saveSession(ResumeSession(section: .feeds, folder: "Archive", feedScope: .all))
        let coordinator = try makeCoordinator()
        let lookup = HeldLookup()
        let navigator = SceneNavigator(
            coordinator: { coordinator }, hasClient: { true }, seed: .feeds,
            feedsLaunchTarget: { _ in await lookup.lookup() }
        )
        let landing = Task { await navigator.mailTreeAppeared(UUID(), isWide: true) }
        try await lookup.waitUntilEntered()
        navigator.layoutIsWide = false

        lookup.release(with: nil)
        await landing.value

        XCTAssertNil(navigator.selectedFolder)
        XCTAssertEqual(coordinator.session.section, .feeds)
    }

    /// A wide tree that reopens the session's feed scope clears the mail
    /// side, as a feed pick does, but is not a pick: a utility tab survives.
    func testAWideHandOffIntoFeedsKeepsAUtilityTab() async throws {
        let coordinator = try makeCoordinator()
        let lookup = HeldLookup()
        let (navigator, _) = await windowReadingMailThenOnFeeds(coordinator, lookup: lookup)
        navigator.showTab(.settings)
        let wide = UUID()
        let handOff = Task { await navigator.mailTreeAppeared(wide, isWide: true) }
        try await lookup.waitUntilEntered()

        lookup.release(with: .all)
        await handOff.value

        XCTAssertEqual(navigator.feeds.scope(in: wide), .all)
        XCTAssertTrue(navigator.splitShowsFeeds)
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
        let handOff = Task { await navigator.mailTreeAppeared(UUID(), isWide: true) }
        try await lookup.waitUntilEntered()

        lookup.release(with: nil)
        await handOff.value

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
        await navigator.mailTreeAppeared(compact, isWide: false)
        navigator.foldersLoaded([inbox])
        navigator.selectMessage(message, isSearching: false, from: compact)

        navigator.navigate(to: NavState(folder: "INBOX", messageID: "<four@example.com>", uid: 4, clientID: "push"))
        await navigator.mailTreeAppeared(UUID(), isWide: true)

        XCTAssertEqual(coordinator.pendingRestore?.uid, 4)
        XCTAssertEqual(coordinator.pendingRestore?.messageID, "<four@example.com>")
    }

    /// A navigation's restore carries the reading position another device
    /// left; a hand-off before the list applies it keeps that restore rather
    /// than re-parking the message bare.
    func testAHandOffKeepsANavigationsReadingPosition() async throws {
        let coordinator = try makeCoordinator()
        let navigator = SceneNavigator(coordinator: { coordinator }, hasClient: { true }, seed: .mail)
        let compact = UUID()
        await navigator.mailTreeAppeared(compact, isWide: false)
        navigator.foldersLoaded([inbox])
        navigator.selectMessage(message, isSearching: false, from: compact)

        navigator.navigate(to: NavState(folder: "INBOX", uid: 4, messageScroll: 640, clientID: "other-install"))
        await navigator.mailTreeAppeared(UUID(), isWide: true)

        XCTAssertEqual(coordinator.pendingRestore?.uid, 4)
        XCTAssertEqual(coordinator.pendingScrollRestore?.offset, 640)
    }

    /// A feed pick in the wide split is a pick: a utility tab carried in
    /// from the compact layout follows it to Feeds.
    func testAFeedPickInTheSplitMovesAUtilityTab() async throws {
        let coordinator = try makeCoordinator()
        let navigator = SceneNavigator(coordinator: { coordinator }, hasClient: { true }, seed: .mail)
        await navigator.mailTreeAppeared(UUID(), isWide: false)
        navigator.foldersLoaded([inbox])
        navigator.showTab(.settings)
        await navigator.mailTreeAppeared(UUID(), isWide: true)

        navigator.showFeeds(.all)

        XCTAssertEqual(navigator.compactTab, .feeds)
    }

    /// A wide window's first landing reopens the session's feed scope, and a
    /// tree that replaced it during the lookup keeps its own landing.
    func testAWideFeedsLandingOpensItsScopeUnlessReplaced() async throws {
        store.saveSession(ResumeSession(section: .feeds, folder: "Archive", feedScope: .all))
        let coordinator = try makeCoordinator()
        let opened = SceneNavigator(
            coordinator: { coordinator }, hasClient: { true }, seed: .feeds, feedsLaunchTarget: { _ in .all }
        )
        await opened.mailTreeAppeared(UUID(), isWide: true)
        XCTAssertEqual(opened.feeds.scope, .all)
        XCTAssertTrue(opened.splitShowsFeeds)
        XCTAssertNil(opened.selectedFolder)
        XCTAssertEqual(opened.route.section, .feeds)

        let lookup = HeldLookup()
        let replaced = SceneNavigator(
            coordinator: { coordinator }, hasClient: { true }, seed: .feeds,
            feedsLaunchTarget: { _ in await lookup.lookup() }
        )
        let landing = Task { await replaced.mailTreeAppeared(UUID(), isWide: true) }
        try await lookup.waitUntilEntered()
        let compact = UUID()
        await replaced.mailTreeAppeared(compact, isWide: false)
        lookup.release(with: .all)

        await landing.value
        XCTAssertNil(replaced.feeds.scope)
        XCTAssertEqual(replaced.folder(in: compact)?.path, "Archive", "the compact tree's landing stands")
    }

    /// On the wide layout, opening a different message is a pick: the tab a
    /// swap back opens on follows it to Mail.
    func testOpeningAnotherMessageInTheSplitMovesAUtilityTab() async throws {
        let coordinator = try makeCoordinator()
        let navigator = SceneNavigator(coordinator: { coordinator }, hasClient: { true }, seed: .mail)
        let compact = UUID()
        await navigator.mailTreeAppeared(compact, isWide: false)
        navigator.foldersLoaded([inbox])
        navigator.showTab(.settings)
        let wide = UUID()
        await navigator.mailTreeAppeared(wide, isWide: true)

        navigator.selectMessage(message, isSearching: false, from: wide)

        XCTAssertEqual(navigator.compactTab, .mail)
    }
}

import XCTest
import CabalmailKit
@testable import CabalmailUI

/// The window's feed reader on its navigator (`SceneNavigator`): the first
/// feed landing, the feed banner, picks on the wide split and the recording.
/// These rules lived as `@State` handlers on `FeedRootView` and on the wide
/// split's `FeedNavigationModifier`, with no test. Layout swaps are
/// `SceneNavigatorFeedHandOffTests`'.
@MainActor
final class SceneNavigatorFeedTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var store: ResumeSessionStore!

    override func setUp() {
        super.setUp()
        suiteName = "SceneNavigatorFeedTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        store = ResumeSessionStore(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private let inbox = Folder(path: "INBOX", isSubscribed: true)
    private let archive = Folder(path: "Archive", isSubscribed: true)
    private let item = RssItem(feedId: "f", subscriptionId: "s", itemId: "i", sortKey: "k")
    private let other = RssItem(feedId: "f", subscriptionId: "s", itemId: "j", sortKey: "l")

    /// A feed-store lookup that waits until the test releases it; any number
    /// of trees may be waiting on it at once.
    @MainActor
    private final class HeldLookup {
        private var held: [CheckedContinuation<RssItemScope?, Never>] = []

        func lookup() async -> RssItemScope? {
            await withCheckedContinuation { held.append($0) }
        }

        func waitUntilEntered(_ count: Int = 1, file: StaticString = #filePath, line: UInt = #line) async throws {
            try await waitUntilOnMainActor(file: file, line: line) { self.held.count >= count }
        }

        func release(with scope: RssItemScope?) {
            held.forEach { $0.resume(returning: scope) }
            held = []
        }
    }

    @MainActor
    private final class Counter {
        var count = 0
    }

    private func makeCoordinator() throws -> NavStateCoordinator {
        let client = try TestFixtures.makeClient(imap: FakeImapClient())
        return NavStateCoordinator(client: client, clientID: "this-install", store: store)
    }

    private func makeNavigator(
        _ coordinator: NavStateCoordinator, seed: ResumeSession.Section = .mail,
        launch: @escaping @MainActor () async -> RssItemScope? = { nil }
    ) -> SceneNavigator {
        SceneNavigator(
            coordinator: { coordinator }, hasClient: { true }, seed: seed, feedsLaunchTarget: { _ in await launch() }
        )
    }

    private struct Window {
        let coordinator: NavStateCoordinator
        let navigator: SceneNavigator
        let tree: UUID
    }

    /// A wide window that landed in the session's feed list, reading `item`.
    private func wideReadingFeed() async throws -> Window {
        store.saveSession(ResumeSession(section: .feeds, feedScope: .all))
        let coordinator = try makeCoordinator()
        let navigator = makeNavigator(coordinator, seed: .feeds, launch: { .all })
        let wide = UUID()
        await navigator.mailTreeAppeared(wide, isWide: true)
        navigator.selectFeedItem(item, from: wide)
        return Window(coordinator: coordinator, navigator: navigator, tree: wide)
    }

    // MARK: Landing

    /// The window's first feed tree reopens the session's scope, records it,
    /// and shows that list; the item parked with it is the list's to apply.
    func testTheFirstFeedTreeLandsOnTheSessionsScope() async throws {
        let coordinator = try makeCoordinator()
        let navigator = makeNavigator(coordinator, seed: .feeds, launch: { .subscription("s") })
        let tree = UUID()

        await navigator.feedTreeAppeared(tree)

        XCTAssertEqual(navigator.feeds.scope(in: tree), .subscription("s"))
        XCTAssertNil(navigator.feeds.item(in: tree))
        XCTAssertEqual(navigator.feeds.column(in: tree), .content)
        XCTAssertTrue(navigator.feeds.didLand)
        XCTAssertEqual(coordinator.session.feedScope, .subscription("s"))
        XCTAssertEqual(navigator.route.feeds.scope, .subscription("s"))
    }

    /// Having landed, the same tree coming back (a tab switch) after the user
    /// left the list doesn't land them in it again.
    func testAFeedTreeAppearingAgainDoesNotLandAgain() async throws {
        let coordinator = try makeCoordinator()
        let lookups = Counter()
        let navigator = makeNavigator(coordinator, seed: .feeds, launch: { lookups.count += 1; return .all })
        let tree = UUID()
        await navigator.feedTreeAppeared(tree)
        navigator.selectFeedScope(nil)

        await navigator.feedTreeAppeared(tree)

        XCTAssertNil(navigator.feeds.scope)
        XCTAssertEqual(lookups.count, 1, "the session's lookup parks its item, so it runs once per window")
    }

    /// A feed banner tapped before the Feeds tab was built is the window's
    /// feed landing: the tree, built by the tab switch, doesn't land on the
    /// session's scope over it.
    func testAFeedBannerBeforeTheFeedTreeIsItsLanding() async throws {
        let coordinator = try makeCoordinator()
        let navigator = makeNavigator(coordinator, launch: { .subscription("session") })
        await navigator.mailTreeAppeared(UUID(), isWide: false)

        navigator.navigateFeeds(to: .all)
        let tree = UUID()
        await navigator.feedTreeAppeared(tree)

        XCTAssertEqual(navigator.compactTab, .feeds)
        XCTAssertEqual(navigator.feeds.scope(in: tree), .all)
    }

    /// A feed tree a swap replaced during the lookup lands nothing; the one
    /// that took over lands instead.
    func testAFeedTreeReplacedDuringItsLookupLandsNothing() async throws {
        let coordinator = try makeCoordinator()
        let lookup = HeldLookup()
        let navigator = makeNavigator(coordinator, seed: .feeds, launch: { await lookup.lookup() })
        let first = UUID()
        let second = UUID()
        let firstLanding = Task { await navigator.feedTreeAppeared(first) }
        try await lookup.waitUntilEntered()
        let secondLanding = Task { await navigator.feedTreeAppeared(second) }
        try await lookup.waitUntilEntered(2)

        lookup.release(with: .all)
        await firstLanding.value
        await secondLanding.value

        XCTAssertNil(navigator.feeds.scope(in: first))
        XCTAssertEqual(navigator.feeds.scope(in: second), .all)
    }

    // MARK: The feed banner

    /// A tapped feed banner opens its scope in this window. On the compact
    /// layout the Feeds tab comes up; on the wide one the split shows feeds,
    /// clearing the mail side, and a swap to compact opens on Feeds.
    func testAFeedBannerOpensItsScopeInThisWindow() async throws {
        let compact = makeNavigator(try makeCoordinator())
        await compact.mailTreeAppeared(UUID(), isWide: false)
        compact.navigateFeeds(to: .subscription("b"))
        XCTAssertEqual(compact.compactTab, .feeds)
        XCTAssertEqual(compact.route.section, .feeds)
        XCTAssertEqual(compact.feeds.scope, .subscription("b"))

        let wide = makeNavigator(try makeCoordinator())
        let tree = UUID()
        await wide.mailTreeAppeared(tree, isWide: true)
        wide.navigateFeeds(to: .subscription("b"))
        XCTAssertTrue(wide.splitShowsFeeds)
        XCTAssertEqual(wide.feeds.scope(in: tree), .subscription("b"))
        XCTAssertNil(wide.folder(in: tree))
        XCTAssertEqual(wide.compactTab, .feeds)
        XCTAssertEqual(wide.feedNavigations, 1, "so the split ends a search, as a feed pick does")
    }

    /// A banner is the window's feed landing even after its list is closed:
    /// the Feeds tab built later doesn't reopen the session's scope.
    func testAFeedBannerStaysTheLandingAfterItsListCloses() async throws {
        let coordinator = try makeCoordinator()
        let lookups = Counter()
        let navigator = makeNavigator(coordinator, launch: { lookups.count += 1; return .subscription("session") })
        await navigator.mailTreeAppeared(UUID(), isWide: true)
        navigator.navigateFeeds(to: .all)
        navigator.selectFolder(inbox)
        navigator.layoutIsWide = false
        navigator.showTab(.feeds)

        await navigator.feedTreeAppeared(UUID())

        XCTAssertNil(navigator.feeds.scope)
        XCTAssertEqual(lookups.count, 0)
    }

    // MARK: The wide split

    /// #1964: a mail navigation in the wide split while a feed is open shows
    /// the message. The feed's place stays for the compact Feeds tab.
    func testAMailNavigationInTheSplitShowsTheMessage() async throws {
        let window = try await wideReadingFeed()
        let (navigator, wide) = (window.navigator, window.tree)

        navigator.navigate(to: NavState(folder: "Archive", uid: 4, clientID: "push"))

        XCTAssertFalse(navigator.splitShowsFeeds)
        XCTAssertEqual(navigator.folder(in: wide)?.path, "Archive")
        XCTAssertEqual(navigator.feeds.scope, .all)
        XCTAssertEqual(navigator.feeds.item, item)
    }

    /// A folder picked while the split shows feeds closes the feed list, and
    /// that is recorded. Picked while it shows mail, it leaves the compact
    /// Feeds tab's place alone.
    func testAWideFolderPickClosesTheFeedListOnlyWhenShown() async throws {
        let window = try await wideReadingFeed()
        let (coordinator, navigator) = (window.coordinator, window.navigator)
        navigator.navigate(to: NavState(folder: "INBOX", clientID: "push"))

        navigator.selectFolder(archive)
        XCTAssertEqual(navigator.feeds.scope, .all)
        XCTAssertEqual(coordinator.session.feedScope, .all)

        navigator.showFeeds(.all)
        navigator.selectFolder(inbox)
        XCTAssertNil(navigator.feeds.scope)
        XCTAssertNil(coordinator.session.feedScope)
        XCTAssertEqual(coordinator.session.section, .mail)
    }

    /// A feed picked in the split while it shows mail opens afresh, even the
    /// scope held for the compact Feeds tab: no item, and the session's item
    /// clears with the scope record.
    func testAWidePickOfTheHeldScopeStartsAfresh() async throws {
        let window = try await wideReadingFeed()
        let (coordinator, navigator, wide) = (window.coordinator, window.navigator, window.tree)
        navigator.navigate(to: NavState(folder: "INBOX", clientID: "push"))

        navigator.showFeeds(.all)

        XCTAssertTrue(navigator.splitShowsFeeds)
        XCTAssertNil(navigator.feeds.item(in: wide))
        XCTAssertNil(coordinator.session.feedItemFeedID)
        XCTAssertNil(navigator.folder(in: wide))
    }

    /// The feed sidebar clearing its selection while the split shows mail
    /// (it has nothing highlighted there) leaves the held place alone.
    func testAClearedFeedSelectionWhileShowingMailChangesNothing() async throws {
        let window = try await wideReadingFeed()
        let (coordinator, navigator) = (window.coordinator, window.navigator)
        navigator.navigate(to: NavState(folder: "INBOX", clientID: "push"))

        navigator.showFeeds(nil)

        XCTAssertEqual(navigator.feeds.scope, .all)
        XCTAssertEqual(coordinator.session.feedScope, .all)
        XCTAssertFalse(navigator.splitShowsFeeds)
    }

    /// Another item picked in the split is a pick: a utility tab carried in
    /// from the compact layout follows it to Feeds.
    func testAFeedItemPickInTheSplitMovesAUtilityTab() async throws {
        let coordinator = try makeCoordinator()
        let navigator = makeNavigator(coordinator, seed: .feeds, launch: { .all })
        let compact = UUID()
        await navigator.feedTreeAppeared(compact)
        navigator.showTab(.settings)
        let wide = UUID()
        await navigator.mailTreeAppeared(wide, isWide: true)
        XCTAssertEqual(navigator.compactTab, .settings)

        navigator.selectFeedItem(other, from: wide)

        XCTAssertEqual(navigator.compactTab, .feeds)
    }

    // MARK: Recording

    /// Opening an item records it; backing out of the reader records that it
    /// closed.
    func testTheReaderIsRecorded() async throws {
        let coordinator = try makeCoordinator()
        let navigator = makeNavigator(coordinator, seed: .feeds, launch: { .all })
        let tree = UUID()
        await navigator.feedTreeAppeared(tree)

        navigator.selectFeedItem(item, from: tree)
        XCTAssertEqual(coordinator.session.feedItemSortKey, "k")
        XCTAssertEqual(navigator.route.feeds.item, AppRoute.Item(item))

        navigator.setFeedColumn(.content, from: tree)
        XCTAssertNil(coordinator.session.feedItemSortKey)
        XCTAssertNil(navigator.route.feeds.item)
    }

    /// Once another feed tree has appeared, the one it replaces can't move
    /// the reader.
    func testWritesFromAReplacedFeedTreeAreDropped() async throws {
        let coordinator = try makeCoordinator()
        let navigator = makeNavigator(coordinator, seed: .feeds, launch: { .all })
        let old = UUID()
        await navigator.feedTreeAppeared(old)
        navigator.selectFeedItem(item, from: old)
        await navigator.feedTreeAppeared(UUID())

        navigator.selectFeedItem(other, from: old)
        navigator.setFeedColumn(.sidebar, from: old)

        XCTAssertEqual(coordinator.session.feedItemSortKey, "k")
    }
}

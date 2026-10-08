import XCTest
import CabalmailKit
@testable import CabalmailUI

/// The feed reader across a layout swap (`SceneNavigator.feedTreeAppeared`,
/// `mailTreeAppeared`): a tree the swap built takes over the window's feed
/// list, and its open item is parked for the new list to select once it has
/// appeared and loaded. Before, both feed trees kept their place as view
/// state, so a fold or a narrowed iPad window lost the open item (#1962).
@MainActor
final class SceneNavigatorFeedHandOffTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var store: ResumeSessionStore!

    override func setUp() {
        super.setUp()
        suiteName = "SceneNavigatorFeedHandOffTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        store = ResumeSessionStore(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private let inbox = Folder(path: "INBOX", isSubscribed: true)
    private let item = RssItem(feedId: "f", subscriptionId: "s", itemId: "i", sortKey: "k")
    private let other = RssItem(feedId: "f", subscriptionId: "s", itemId: "j", sortKey: "l")
    private let scope = RssItemScope.subscription("s")

    private func makeCoordinator() throws -> NavStateCoordinator {
        let client = try TestFixtures.makeClient(imap: FakeImapClient())
        return NavStateCoordinator(client: client, clientID: "this-install", store: store)
    }

    /// A compact window on the Feeds tab, reading `item` in `scope`.
    private func compactReadingFeed(
        _ coordinator: NavStateCoordinator
    ) async -> (navigator: SceneNavigator, tab: UUID) {
        let scope = scope
        let navigator = SceneNavigator(
            coordinator: { coordinator }, hasClient: { true }, seed: .feeds, feedsLaunchTarget: { _ in scope }
        )
        let tab = UUID()
        await navigator.feedTreeAppeared(tab)
        navigator.selectFeedItem(item, from: tab)
        return (navigator, tab)
    }

    /// #1962: widening (or unfolding) while reading a feed item. The wide
    /// split shows the window's list, and the item is parked for that list
    /// rather than handed over with it, so a list and its reader never arrive
    /// in one update. The session keeps the item: nothing moved.
    func testWideningKeepsTheOpenFeedItem() async throws {
        let coordinator = try makeCoordinator()
        let (navigator, _) = await compactReadingFeed(coordinator)
        let wide = UUID()

        await navigator.mailTreeAppeared(wide, isWide: true)

        XCTAssertTrue(navigator.splitShowsFeeds)
        XCTAssertEqual(navigator.feeds.scope(in: wide), scope)
        XCTAssertNil(navigator.feeds.item(in: wide), "the list selects it once loaded")
        XCTAssertEqual(coordinator.pendingFeedRestore, NavStateCoordinator.PendingFeedRestore(scope: scope, item: item))
        XCTAssertEqual(coordinator.session.feedItemSortKey, "k")
        XCTAssertNil(navigator.folder(in: wide))

        // The window landed in the feed reader: the wide sidebar's folder
        // list arriving doesn't land mail behind it.
        navigator.foldersLoaded([inbox])
        XCTAssertTrue(navigator.splitShowsFeeds)
        XCTAssertNil(navigator.folder(in: wide))
        XCTAssertEqual(coordinator.session.section, .feeds)
    }

    /// The same for a window that has used both tabs, whose wide tree takes
    /// over a mail tree too: the split shows the feed, not mail.
    func testWideningAfterUsingBothTabsKeepsTheFeed() async throws {
        let coordinator = try makeCoordinator()
        let (navigator, _) = await compactReadingFeed(coordinator)
        navigator.showTab(.mail)
        await navigator.mailTreeAppeared(UUID(), isWide: false)
        navigator.showTab(.feeds)
        let wide = UUID()

        await navigator.mailTreeAppeared(wide, isWide: true)

        XCTAssertTrue(navigator.splitShowsFeeds)
        XCTAssertEqual(navigator.route.section, .feeds)
        XCTAssertEqual(navigator.feeds.scope(in: wide), scope)
        XCTAssertEqual(coordinator.pendingFeedRestore?.item, item)
        XCTAssertNil(navigator.folder(in: wide), "the mail side clears, as for a feed pick")

        // So a mail navigation to the folder the Mail tab had is a folder
        // change that shows the message (#1964).
        navigator.navigate(to: NavState(folder: "INBOX", uid: 4, clientID: "push"))
        XCTAssertFalse(navigator.splitShowsFeeds)
        XCTAssertEqual(navigator.folder(in: wide)?.path, "INBOX")
    }

    /// An item picked before the list applied the one parked for it (a
    /// launch restore still waiting on the first sync) wins: the parked one
    /// goes, and a swap parks the pick.
    func testAPickBeforeTheParkedItemOpensWinsTheHandOff() async throws {
        let coordinator = try makeCoordinator()
        let (navigator, tab) = await compactReadingFeed(coordinator)
        navigator.setFeedColumn(.content, from: tab)
        coordinator.pendingFeedRestore = NavStateCoordinator.PendingFeedRestore(scope: scope, item: other)

        navigator.selectFeedItem(item, from: tab)
        XCTAssertNil(coordinator.pendingFeedRestore)

        await navigator.mailTreeAppeared(UUID(), isWide: true)
        XCTAssertEqual(coordinator.pendingFeedRestore?.item, item)
    }

    /// A list picked over the one an item is parked for makes that item
    /// stale: it would otherwise open when the list came back. A banner's
    /// item, parked for the list it opens, stays.
    func testAScopeChangeDropsAnItemParkedForAnotherList() async throws {
        let coordinator = try makeCoordinator()
        let (navigator, _) = await compactReadingFeed(coordinator)
        coordinator.pendingFeedRestore = NavStateCoordinator.PendingFeedRestore(scope: scope, item: other)

        navigator.selectFeedScope(.all)
        XCTAssertNil(coordinator.pendingFeedRestore)

        coordinator.pendingFeedRestore = NavStateCoordinator.PendingFeedRestore(scope: scope, item: other)
        navigator.navigateFeeds(to: scope)
        XCTAssertEqual(coordinator.pendingFeedRestore?.item, other)
    }

    /// The other way: narrowing (or folding) while reading in the wide split
    /// hands the item to the Feeds tab's list the same way.
    func testNarrowingKeepsTheOpenFeedItem() async throws {
        store.saveSession(ResumeSession(section: .feeds, feedScope: scope))
        let coordinator = try makeCoordinator()
        let scope = scope
        let navigator = SceneNavigator(
            coordinator: { coordinator }, hasClient: { true }, seed: .feeds, feedsLaunchTarget: { _ in scope }
        )
        let wide = UUID()
        await navigator.mailTreeAppeared(wide, isWide: true)
        navigator.selectFeedItem(item, from: wide)
        let tab = UUID()

        await navigator.feedTreeAppeared(tab)

        XCTAssertEqual(navigator.feeds.scope(in: tab), scope)
        XCTAssertNil(navigator.feeds.item(in: tab))
        XCTAssertEqual(navigator.feeds.column(in: tab), .content)
        XCTAssertEqual(coordinator.pendingFeedRestore, NavStateCoordinator.PendingFeedRestore(scope: scope, item: item))
    }

    /// The parked item coming back is the window restoring its place, not a
    /// pick: a utility tab the user was on before widening survives.
    func testTheRestoredItemIsNotAPick() async throws {
        let coordinator = try makeCoordinator()
        let (navigator, _) = await compactReadingFeed(coordinator)
        navigator.showTab(.settings)
        let wide = UUID()
        await navigator.mailTreeAppeared(wide, isWide: true)

        navigator.selectFeedItem(item, from: wide)

        XCTAssertEqual(navigator.feeds.item(in: wide), item)
        XCTAssertEqual(navigator.compactTab, .settings)
    }

    /// Backed out to the feed list on the Feeds tab, then widened: the
    /// window has no list to show, so the split shows mail, rather than
    /// reopening the scope the window landed on.
    func testWideningFromTheFeedListShowsMail() async throws {
        let coordinator = try makeCoordinator()
        let (navigator, tab) = await compactReadingFeed(coordinator)
        navigator.showTab(.mail)
        await navigator.mailTreeAppeared(UUID(), isWide: false)
        navigator.showTab(.feeds)
        navigator.setFeedColumn(.content, from: tab)
        navigator.selectFeedScope(nil)
        let wide = UUID()

        await navigator.mailTreeAppeared(wide, isWide: true)

        XCTAssertFalse(navigator.splitShowsFeeds)
        XCTAssertNil(navigator.feeds.scope)
        XCTAssertEqual(navigator.route.section, .mail)
        XCTAssertEqual(navigator.folder(in: wide)?.path, "INBOX")
    }

    /// A feed banner's item still waiting for its list when the swap comes
    /// is newer than the one open, and carries its reading position: the
    /// hand-off leaves it parked.
    func testAHandOffKeepsABannersParkedItem() async throws {
        let coordinator = try makeCoordinator()
        let (navigator, _) = await compactReadingFeed(coordinator)
        coordinator.pendingFeedRestore = NavStateCoordinator.PendingFeedRestore(scope: scope, item: other)
        navigator.navigateFeeds(to: scope)

        await navigator.mailTreeAppeared(UUID(), isWide: true)

        XCTAssertEqual(coordinator.pendingFeedRestore?.item, other)
    }

    /// Widening from the Mail tab: the split shows mail, and the Feeds tab's
    /// list and item stay where they were, neither parked nor recorded away.
    /// Narrowing back hands the item to the rebuilt Feeds tab.
    func testTheSplitShowingMailKeepsTheFeedsTabsPlace() async throws {
        let coordinator = try makeCoordinator()
        let (navigator, _) = await compactReadingFeed(coordinator)
        navigator.showTab(.mail)
        await navigator.mailTreeAppeared(UUID(), isWide: false)
        navigator.foldersLoaded([inbox])
        let wide = UUID()

        await navigator.mailTreeAppeared(wide, isWide: true)
        XCTAssertFalse(navigator.splitShowsFeeds)
        XCTAssertEqual(navigator.folder(in: wide), inbox)
        XCTAssertEqual(navigator.feeds.item, item)
        XCTAssertNil(coordinator.pendingFeedRestore)
        XCTAssertEqual(coordinator.session.feedItemSortKey, "k")

        await navigator.feedTreeAppeared(UUID())
        XCTAssertEqual(coordinator.pendingFeedRestore, NavStateCoordinator.PendingFeedRestore(scope: scope, item: item))
    }
}

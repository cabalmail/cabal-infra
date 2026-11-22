import XCTest
import CoreSpotlight
import CabalmailKit
@testable import CabalmailUI

/// A Spotlight result for a feed item (`DeepLink.feedItem`): the window that
/// takes it goes to the item's own feed, whose list opens the item; a cold
/// launch from one lands there; and a result the account can no longer open
/// opens nothing.
///
/// The client is the factory's, over a recording index and a transport that
/// reaches nothing, so the feed store is real and no test touches the
/// device's Spotlight index or the network.
@MainActor
final class FeedItemDeepLinkTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var root: URL!
    private var index: FakeSearchableIndex!
    private var client: CabalmailClient!
    private var coordinator: NavStateCoordinator!
    private var router: DeepLinkRouter!

    private let subscription = RssSubscription(subscriptionId: "s1", feedId: "f1")
    private let sortKey = "2026-01-02T00:00:00+00:00#i1"
    /// The item as the feed store holds it.
    private var item: RssItem!
    private var link: DeepLink { .feedItem(feedID: "f1", sortKey: sortKey) }

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "FeedItemDeepLinkTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        root = FileManager.default.temporaryDirectory.appendingPathComponent("feed-link-\(UUID().uuidString)")
        index = FakeSearchableIndex()
        client = try CabalmailClient.make(
            configuration: TestFixtures.makeConfiguration(), secureStore: InMemorySecureStore(),
            httpTransport: UnreachableTransport(), cacheDirectory: root, searchableIndex: index
        )
        let store = try XCTUnwrap(client.rssStore)
        try await store.upsertSubscription(subscription)
        try await store.upsertItems([RssItem(feedId: "f1", itemId: "i1", sortKey: sortKey, title: "One")])
        let stored = try await store.item(feedId: "f1", sortKey: sortKey)
        item = try XCTUnwrap(stored)
        router = DeepLinkRouter()
        launch()
    }

    /// The session's coordinator, as a launch makes it: it reads the saved
    /// session when it is made, so a test that saves one launches again.
    private func launch(after session: ResumeSession? = nil) {
        let store = ResumeSessionStore(defaults: defaults)
        if let session { store.saveSession(session) }
        coordinator = NavStateCoordinator(client: client, clientID: "this-install", store: store)
    }

    private let onLists = ResumeSession(section: .mail, folder: "Lists", uid: 42)

    override func tearDown() async throws {
        await client.shutdown()
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
        try await super.tearDown()
    }

    /// A main window registered with the router.
    private func window(seed: ResumeSession.Section = .mail) -> SceneNavigator {
        let coordinator = coordinator!
        let navigator = SceneNavigator(
            coordinator: { coordinator }, hasClient: { true }, seed: seed, deepLinks: router
        )
        navigator.windowID = UUID()
        router.register(navigator)
        return navigator
    }

    private var itemParked: WindowRestores.PendingFeedRestore {
        WindowRestores.PendingFeedRestore(scope: .subscription("s1"), item: item)
    }

    /// Waits for the lookup of the link `navigator` was last sent: the store
    /// reads, and the fetch the unreachable transport refuses.
    private func settle(_ navigator: SceneNavigator) async {
        await navigator.opening?.value
    }

    // MARK: Opening

    func testAFeedResultOpensItsFeedWithTheItemForTheList() async throws {
        let navigator = window()
        await navigator.mailTreeAppeared(UUID(), isWide: false)
        XCTAssertEqual(navigator.compactTab, .mail, "precondition")

        router.open(link, in: navigator.windowID)

        try await waitUntilOnMainActor { navigator.feeds.scope == .subscription("s1") }
        XCTAssertEqual(navigator.compactTab, .feeds)
        XCTAssertEqual(navigator.route.section, .feeds)
        XCTAssertEqual(navigator.restores.pendingFeedRestore, itemParked, "the list opens the item once loaded")
        XCTAssertNil(navigator.feeds.item, "never selected in the same step as the list (#1664)")
        XCTAssertEqual(coordinator.session.section, .feeds)
        let deleted = await index.deletedDomains
        XCTAssertTrue(deleted.isEmpty, "a result that opens takes nothing out of the index")
    }

    /// In the wide split, which hosts feeds beside mail: the mail side
    /// clears, as for a feed pick.
    func testAFeedResultInTheSplitShowsTheFeed() async throws {
        let navigator = window()
        await navigator.mailTreeAppeared(UUID(), isWide: true)
        XCTAssertEqual(navigator.selectedFolder?.path, "INBOX", "precondition: landed in mail")

        router.open(link, in: navigator.windowID)

        try await waitUntilOnMainActor { navigator.splitShowsFeeds }
        XCTAssertEqual(navigator.feeds.scope, .subscription("s1"))
        XCTAssertNil(navigator.selectedFolder)
        XCTAssertEqual(navigator.restores.pendingFeedRestore, itemParked)
    }

    /// Only the window it was sent to moves.
    func testOnlyTheTargetedWindowOpensIt() async throws {
        let first = window()
        let second = window()

        router.open(link, in: first.windowID)

        try await waitUntilOnMainActor { first.feeds.scope != nil }
        XCTAssertNil(second.feeds.scope)
        XCTAssertNil(second.restores.pendingFeedRestore)
        XCTAssertEqual(second.compactTab, .mail)
    }

    // MARK: A cold launch

    /// A result chosen before any window exists parks, and the first window
    /// takes it as it registers. It is that window's landing: its Mail tab
    /// does not then land on the session's folder, which would record the
    /// session out of the feed the user was sent to.
    func testAParkedFeedResultIsTheLanding() async throws {
        launch(after: onLists)
        router.open(link)
        XCTAssertEqual(router.parked, link, "precondition: parked with no window")

        let navigator = window()
        XCTAssertNil(router.parked, "taken at registration")
        await navigator.mailTreeAppeared(UUID(), isWide: false)

        XCTAssertEqual(navigator.feeds.scope, .subscription("s1"))
        XCTAssertEqual(navigator.compactTab, .feeds)
        XCTAssertEqual(navigator.restores.pendingFeedRestore, itemParked)
        XCTAssertNil(navigator.selectedFolder, "the session's mail landing did not run")
        XCTAssertFalse(navigator.awaitingLaunchReconcile)
        XCTAssertEqual(coordinator.session.section, .feeds)
        XCTAssertTrue(navigator.didLand)
    }

    /// The same in a wide window: the split lands in the feed, not on the
    /// session's folder behind it.
    func testAParkedFeedResultLandsTheSplitInTheFeed() async throws {
        launch(after: onLists)
        router.open(link)

        let navigator = window()
        await navigator.mailTreeAppeared(UUID(), isWide: true)

        XCTAssertTrue(navigator.splitShowsFeeds)
        XCTAssertEqual(navigator.feeds.scope, .subscription("s1"))
        XCTAssertNil(navigator.selectedFolder)
        XCTAssertEqual(navigator.restores.pendingFeedRestore, itemParked)
    }

    /// A window opened after the result landed the first lands where the
    /// user went, not where the process started (#1966): its Feeds tab opens
    /// the feed, with the item.
    func testAWindowOpenedAfterAFeedResultLandsWhereItWent() async throws {
        launch(after: onLists)
        router.open(link)
        let first = window()
        await first.mailTreeAppeared(UUID(), isWide: false)
        // The first window's list opened the item, which records it.
        let list = UUID()
        await first.feedTreeAppeared(list)
        first.selectFeedItem(item, from: list)

        let second = window()
        await second.feedTreeAppeared(UUID())

        XCTAssertEqual(second.feeds.scope, .subscription("s1"))
        XCTAssertEqual(second.restores.pendingFeedRestore, itemParked)
    }

    /// The control for the ones above: with no link, the same launch lands on
    /// the session's folder.
    func testWithNoLinkTheSameLaunchLandsOnTheSessionsFolder() async throws {
        launch(after: onLists)

        let navigator = window()
        await navigator.mailTreeAppeared(UUID(), isWide: false)

        XCTAssertEqual(navigator.selectedFolder?.path, "Lists")
        XCTAssertNil(navigator.feeds.scope)
        XCTAssertEqual(navigator.compactTab, .mail)
    }

    // MARK: Giving way

    /// The lookup gives way to a navigation made while it ran.
    func testAFeedResultGivesWayToANavigationMeanwhile() async throws {
        let navigator = window()

        router.open(link, in: navigator.windowID)
        navigator.navigate(to: NavState(folder: "INBOX", uid: 4, clientID: "other-install"))
        await settle(navigator)

        XCTAssertEqual(navigator.selectedFolder?.path, "INBOX")
        XCTAssertNil(navigator.feeds.scope)
        XCTAssertNil(navigator.restores.pendingFeedRestore)
        XCTAssertEqual(navigator.compactTab, .mail)
    }

    // MARK: Results that cannot open

    /// A feed the account no longer has (left on another device after its
    /// items were indexed here): nothing opens, and the feed's results are
    /// taken out of Spotlight.
    func testAResultForAFeedTheAccountLeftOpensNothingAndIsForgotten() async throws {
        let navigator = window()
        await navigator.mailTreeAppeared(UUID(), isWide: false)
        let before = navigator.route

        router.open(.feedItem(feedID: "gone", sortKey: "k"), in: navigator.windowID)
        await settle(navigator)

        XCTAssertEqual(navigator.route, before)
        XCTAssertNil(navigator.feeds.scope)
        XCTAssertNil(navigator.restores.pendingFeedRestore)
        let deleted = await index.deletedDomains
        XCTAssertEqual(deleted, [[SpotlightFeedItemRef.domainIdentifier(feedID: "gone")]])
    }

    /// An item of a feed the account has that is neither on the device nor
    /// fetchable just now: nothing opens, and nothing is forgotten, since
    /// the item may well be there.
    func testAResultWhoseItemCannotBeFoundOpensNothingAndKeepsTheFeed() async throws {
        let navigator = window()
        await navigator.mailTreeAppeared(UUID(), isWide: false)
        let before = navigator.route

        router.open(.feedItem(feedID: "f1", sortKey: "not-on-the-device"), in: navigator.windowID)
        await settle(navigator)

        XCTAssertEqual(navigator.route, before)
        XCTAssertNil(navigator.feeds.scope)
        let deleted = await index.deletedDomains
        XCTAssertTrue(deleted.isEmpty)
    }

    /// A window that has not landed and is sent a result that cannot open
    /// still lands where the session was.
    func testAParkedResultThatCannotOpenLeavesTheLaunchToTheSession() async throws {
        launch(after: onLists)
        router.open(.feedItem(feedID: "gone", sortKey: "k"))

        let navigator = window()
        await navigator.mailTreeAppeared(UUID(), isWide: false)

        XCTAssertEqual(navigator.selectedFolder?.path, "Lists")
        XCTAssertNil(navigator.feeds.scope)
    }

    // MARK: From the activity

    private func activity(identifier: String) -> NSUserActivity {
        let activity = NSUserActivity(activityType: CSSearchableItemActionType)
        activity.userInfo = [CSSearchableItemActivityIdentifier: identifier]
        return activity
    }

    func testAChosenResultNamesAMessageOrAFeedItem() {
        let feedItem = SpotlightFeedItemRef(feedID: "f1", sortKey: sortKey)
        let message = SpotlightMessageRef(folder: "Archive", uid: 9)

        XCTAssertEqual(DeepLink(spotlightActivity: activity(identifier: feedItem.stringValue)), link)
        XCTAssertEqual(DeepLink(spotlightActivity: activity(identifier: message.stringValue)), .spotlight(message))
        XCTAssertNil(DeepLink(spotlightActivity: activity(identifier: "com.example.other|1")))
        XCTAssertNil(DeepLink(spotlightActivity: NSUserActivity(activityType: CSSearchableItemActionType)))
    }

    /// The app's entry point for a chosen result, with no window to take it:
    /// a feed item's parks as a message's does.
    func testAFeedResultActivityParksUntilAWindowOpens() {
        let state = AppState()
        let feedItem = SpotlightFeedItemRef(feedID: "f1", sortKey: sortKey)

        state.handleSpotlightActivity(activity(identifier: feedItem.stringValue))

        XCTAssertEqual(state.deepLinks.parked, link)
    }

    /// The link's cursor is a feed cursor for the item, so nothing that
    /// reads a link's cursor takes it for a folder.
    func testAFeedLinksCursorNamesTheItem() async {
        let cursor = await coordinator.cursor(for: link)

        XCTAssertEqual(cursor.kind, .rss)
        XCTAssertEqual(cursor.rssItemParts?.feedID, "f1")
        XCTAssertEqual(cursor.rssItemParts?.sortKey, sortKey)
        XCTAssertNil(coordinator.immediateCursor(for: link), "it opens once looked up, not at once")
    }
}

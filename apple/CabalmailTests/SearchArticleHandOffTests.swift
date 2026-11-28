import XCTest
import CabalmailKit
@testable import CabalmailUI

/// An article open from a search across a change of layout shell
/// (flags-and-cross-media.md, decision 17): carried as an open message is
/// (#2184), by the same rules, and the scope with it. And what a search
/// opens on, as the navigator reads the window: the tab Search was opened
/// from.
@MainActor
final class SearchArticleHandOffTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var store: ResumeSessionStore!
    private var appState: AppState!

    override func setUp() async throws {
        suiteName = "SearchArticleHandOffTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        store = ResumeSessionStore(defaults: defaults)
        appState = AppState()
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private let inbox = Folder(path: "INBOX", isSubscribed: true)
    private let message = TestFixtures.makeEnvelope(uid: 9, messageId: "<nine@example.com>")
    private let article = RssItem(
        feedId: "f1", subscriptionId: "s1", itemId: "a", sortKey: "2026-03-05T12:00:00Z#a", title: "Ferry strike",
        publishedAt: "2026-03-05T12:00:00Z"
    )

    private func makeNavigator(seed: ResumeSession.Section = .mail) throws -> SceneNavigator {
        let coordinator = try NavStateCoordinator(
            client: TestFixtures.makeClient(imap: FakeImapClient()),
            clientID: "this-install",
            store: store
        )
        return SceneNavigator(coordinator: { coordinator }, hasClient: { true }, seed: seed)
    }

    /// The window's search model, as its search field or Search tab takes it.
    @discardableResult
    private func search(in navigator: SceneNavigator) throws -> MessageListViewModel {
        navigator.searchModel(
            client: try TestFixtures.makeClient(imap: FakeImapClient()),
            preferences: Preferences(store: InMemoryPreferenceStore()),
            mailStore: appState.mailStore
        )
    }

    /// A wide window with a search typed and an article open from it.
    private func readingAnArticleWide() async throws -> (SceneNavigator, UUID) {
        let navigator = try makeNavigator()
        navigator.layoutChanged(wasWide: true, isWide: true)
        let split = UUID()
        await navigator.mailTreeAppeared(split, isWide: true)
        navigator.selectFolder(inbox)
        try search(in: navigator).searchQuery = "ferry"
        navigator.searchPlace.openArticle = article
        return (navigator, split)
    }

    // MARK: The rules

    func testTheHandOffHoldsAMessageOrAnArticleNeverBoth() {
        var handOff = ShellHandOff()
        handOff.searchResultChanged(message)

        handOff.searchArticleChanged(article)
        XCTAssertNil(handOff.searchResult, "the article replaced the message")
        XCTAssertEqual(handOff.searchArticle, article)

        handOff.searchResultChanged(message)
        XCTAssertNil(handOff.searchArticle, "and a message replaces the article")
    }

    func testClosingTheArticleLeavesAMessageResultAlone() {
        var handOff = ShellHandOff()
        handOff.searchResultChanged(message)

        handOff.searchArticleChanged(nil)

        XCTAssertEqual(handOff.searchResult, message)
    }

    func testAMessageOpenedOutsideSearchDropsTheArticle() {
        var handOff = ShellHandOff()
        handOff.searchArticleChanged(article)

        handOff.searchResultChanged(nil)

        XCTAssertNil(handOff.searchArticle, "the window is no longer reading a result")
    }

    func testTheArticleIsTakenOnce() {
        var handOff = ShellHandOff()
        handOff.searchArticleChanged(article)

        XCTAssertEqual(handOff.takeSearchArticle(), article)
        XCTAssertNil(handOff.takeSearchArticle())
    }

    func testANarrowingWithNoSearchEngagedDropsTheArticle() {
        var handOff = ShellHandOff()
        handOff.searchArticleChanged(article)

        let step = handOff.layoutChanged(wasWide: true, isWide: false, tab: .mail, searchIsEngaged: false)

        XCTAssertEqual(step, .nothing)
        XCTAssertNil(handOff.searchArticle)
    }

    func testAWideningFromAnotherTabEndsTheSearchAndDropsTheArticle() {
        var handOff = ShellHandOff()
        handOff.searchArticleChanged(article)

        let step = handOff.layoutChanged(wasWide: false, isWide: true, tab: .feeds, searchIsEngaged: true)

        XCTAssertEqual(step, .endLeftoverSearch)
        XCTAssertNil(handOff.searchArticle)
    }

    // MARK: The round trip

    func testAnArticleOpenInTheSplitIsPushedInTheSearchTabAndComesBack() async throws {
        let (navigator, _) = try await readingAnArticleWide()

        navigator.layoutChanged(wasWide: true, isWide: false)
        let tabs = UUID()
        await navigator.mailTreeAppeared(tabs, isWide: false)

        XCTAssertEqual(navigator.compactTab, .search, "the search carries, so its tab is in front")
        XCTAssertNil(navigator.searchPlace.openArticle, "the split's reader is gone")
        // What `SearchView` does on appear, and then reports.
        let handedOff = navigator.takeHandedOffSearchArticle()
        XCTAssertEqual(handedOff, article, "the Search tab takes the article and pushes it")
        XCTAssertNil(navigator.takeHandedOffSearchResult())
        navigator.searchTabArticleChanged(handedOff)

        navigator.layoutChanged(wasWide: false, isWide: true)
        let resplit = UUID()
        await navigator.mailTreeAppeared(resplit, isWide: true)

        XCTAssertEqual(navigator.searchPlace.openArticle, article, "the widen brings it back to the reader")
        XCTAssertNil(navigator.envelope(in: resplit))
    }

    func testAnArticleLeftInTheSearchTabIsNotReopenedByTheWiden() async throws {
        let (navigator, _) = try await readingAnArticleWide()
        navigator.layoutChanged(wasWide: true, isWide: false)
        let tabs = UUID()
        await navigator.mailTreeAppeared(tabs, isWide: false)
        _ = navigator.takeHandedOffSearchArticle()
        // The reader popped in the Search tab: back to the results.
        navigator.searchTabArticleChanged(nil)

        navigator.layoutChanged(wasWide: false, isWide: true)
        let resplit = UUID()
        await navigator.mailTreeAppeared(resplit, isWide: true)

        XCTAssertNil(navigator.searchPlace.openArticle)
    }

    func testTheScopeCarriesAcrossTheSwap() async throws {
        let (navigator, _) = try await readingAnArticleWide()
        await navigator.searchPlace.pick(.feeds)

        navigator.layoutChanged(wasWide: true, isWide: false)
        let tabs = UUID()
        await navigator.mailTreeAppeared(tabs, isWide: false)

        XCTAssertEqual(navigator.searchPlace.scope, .feeds)
    }

    func testASearchLeftBehindInItsTabEndsForBothHalvesOnTheWiden() async throws {
        let navigator = try makeNavigator()
        navigator.layoutChanged(wasWide: false, isWide: false)
        let tabs = UUID()
        await navigator.mailTreeAppeared(tabs, isWide: false)
        navigator.selectTab(.search)
        try search(in: navigator).searchQuery = "ferry"
        await navigator.searchPlace.pick(.feeds)
        navigator.searchTabArticleChanged(article)
        // The user went back to Mail with the search still in its tab.
        navigator.selectTab(.mail)

        navigator.layoutChanged(wasWide: false, isWide: true)
        let split = UUID()
        await navigator.mailTreeAppeared(split, isWide: true)

        XCTAssertNil(navigator.searchPlace.openArticle)
        XCTAssertEqual(navigator.searchPlace.scope, .all, "the pick went with the search")
        XCTAssertEqual(try search(in: navigator).searchQuery, "")
    }

    // MARK: What the Search tab opens on

    func testSearchOpenedFromMailOpensOnMail() async throws {
        let navigator = try makeNavigator()
        try search(in: navigator)

        navigator.selectTab(.search)

        XCTAssertEqual(navigator.compactTab, .search)
        XCTAssertEqual(navigator.searchPlace.scope, .mail)
    }

    func testSearchOpenedFromFeedsOpensOnFeeds() async throws {
        let navigator = try makeNavigator()
        try search(in: navigator)
        navigator.selectTab(.feeds)

        navigator.selectTab(.search)

        XCTAssertEqual(navigator.searchPlace.scope, .feeds)
    }

    func testSearchOpenedFromATabOfNeitherMediumOpensOnAll() async throws {
        let navigator = try makeNavigator()
        try search(in: navigator)
        navigator.selectTab(.feeds)
        navigator.selectTab(.search)
        XCTAssertEqual(navigator.searchPlace.scope, .feeds)
        navigator.selectTab(.settings)

        navigator.selectTab(.search)

        XCTAssertEqual(navigator.searchPlace.scope, .all)
    }

    func testASearchStillInItsFieldKeepsItsScopeWhenTheTabIsOpenedAgain() async throws {
        let navigator = try makeNavigator()
        let model = try search(in: navigator)
        navigator.selectTab(.search)
        XCTAssertEqual(navigator.searchPlace.scope, .mail)
        model.searchQuery = "ferry"
        navigator.selectTab(.feeds)

        navigator.selectTab(.search)

        XCTAssertEqual(navigator.searchPlace.scope, .mail, "the same search, where it was")
    }

    func testTappingSearchWhileItIsInFrontChangesNothing() async throws {
        let navigator = try makeNavigator()
        try search(in: navigator)
        navigator.selectTab(.feeds)
        navigator.selectTab(.search)

        navigator.selectTab(.search)

        XCTAssertEqual(navigator.searchPlace.scope, .feeds, "Search is not a medium to open over")
    }

    func testSearchOpenedOverTheFlaggedViewOpensOnAll() async throws {
        let navigator = try makeNavigator()
        try search(in: navigator)
        navigator.layoutChanged(wasWide: false, isWide: false)
        let tabs = UUID()
        await navigator.mailTreeAppeared(tabs, isWide: false)
        navigator.showFlagged(from: tabs, door: .mail)
        XCTAssertTrue(navigator.flaggedIsInFront)

        navigator.selectTab(.search)

        XCTAssertEqual(navigator.searchPlace.scope, .all, "the view in front lists both media")
    }

    func testALayoutReportThatChangesNothingLeavesTheArticleOpen() async throws {
        let (navigator, _) = try await readingAnArticleWide()

        // A resize within the wide layout reports again: wide before, wide after.
        navigator.layoutChanged(wasWide: true, isWide: true)

        XCTAssertEqual(navigator.searchPlace.openArticle, article)
        XCTAssertNil(navigator.takeHandedOffSearchArticle(), "nothing was handed on: no layout was left")
    }

    func testATabPickThatIsNotSearchNotesNothing() async throws {
        let navigator = try makeNavigator()
        try search(in: navigator)
        navigator.selectTab(.feeds)
        navigator.selectTab(.search)
        XCTAssertEqual(navigator.searchPlace.scope, .feeds)
        // Search is left for Mail, then Addresses: neither is a search opening.
        navigator.selectTab(.mail)
        navigator.selectTab(.addresses)

        XCTAssertEqual(navigator.searchPlace.scope, .feeds, "the scope moves only when Search is opened")
    }
}

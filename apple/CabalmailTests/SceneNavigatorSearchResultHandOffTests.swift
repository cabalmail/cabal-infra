import XCTest
import CabalmailKit
@testable import CabalmailUI

/// The open search result across a change of layout shell (#2184, #2033's
/// first half): the window carries it, so a result open in the split's reader
/// is pushed in the Search tab after a narrowing and back in the reader after
/// the widening. The rules alone are `ShellHandOffTests`; the rest of what a
/// swap carries is `SceneNavigatorShellTransitionTests`.
@MainActor
final class SceneNavigatorSearchResultHandOffTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var store: ResumeSessionStore!
    private var appState: AppState!

    override func setUp() async throws {
        suiteName = "SceneNavigatorSearchResultHandOffTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        store = ResumeSessionStore(defaults: defaults)
        appState = AppState()
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private let inbox = Folder(path: "INBOX", isSubscribed: true)
    private let message = TestFixtures.makeEnvelope(uid: 9, messageId: "<nine@example.com>")

    /// The window's search model, as its search field or Search tab takes it.
    private func search(in navigator: SceneNavigator) throws -> MessageListViewModel {
        navigator.searchModel(
            client: try TestFixtures.makeClient(imap: FakeImapClient()),
            preferences: Preferences(store: InMemoryPreferenceStore()),
            mailStore: appState.mailStore
        )
    }

    /// A wide window reading a result in its split: the layout report, the
    /// split's tree, a folder, a query, and the result open.
    private func readingAResultWide() async throws -> (SceneNavigator, UUID) {
        let coordinator = try NavStateCoordinator(
            client: TestFixtures.makeClient(imap: FakeImapClient()),
            clientID: "this-install",
            store: store
        )
        let navigator = SceneNavigator(coordinator: { coordinator }, hasClient: { true }, seed: .mail)
        navigator.layoutChanged(wasWide: true, isWide: true)
        let split = UUID()
        await navigator.mailTreeAppeared(split, isWide: true)
        navigator.selectFolder(inbox)
        try search(in: navigator).searchQuery = "invoice"
        return (navigator, split)
    }

    /// The whole round trip the report names: a result open in the split's
    /// reader is pushed in the Search tab after a narrowing, and back in the
    /// split's reader after the widening.
    func testTheOpenSearchResultSurvivesANarrowAndTheWidenBack() async throws {
        let (navigator, split) = try await readingAResultWide()
        navigator.selectMessage(message, isSearching: true, from: split)
        XCTAssertEqual(navigator.envelope(in: split), message, "the split's reader has the result")

        navigator.layoutChanged(wasWide: true, isWide: false)
        let tabs = UUID()
        await navigator.mailTreeAppeared(tabs, isWide: false)

        XCTAssertEqual(navigator.compactTab, .search)
        XCTAssertNil(navigator.envelope(in: tabs), "the tab layout's reader is the Search tab's own")
        // What `SearchView` does on appear, and then reports.
        let handedOff = navigator.takeHandedOffSearchResult()
        XCTAssertEqual(handedOff, message, "the Search tab takes the result and pushes it")
        navigator.searchTabResultChanged(handedOff)

        navigator.layoutChanged(wasWide: false, isWide: true)
        let resplit = UUID()
        await navigator.mailTreeAppeared(resplit, isWide: true)

        XCTAssertEqual(navigator.envelope(in: resplit), message, "the widen brings the result back")
    }

    /// The Search tab with nothing open hands nothing back, so the widening
    /// shows the results with an empty reader rather than the result the
    /// window read before the user left it.
    func testAResultLeftInTheSearchTabIsNotReopenedByTheWiden() async throws {
        let (navigator, split) = try await readingAResultWide()
        navigator.selectMessage(message, isSearching: true, from: split)

        navigator.layoutChanged(wasWide: true, isWide: false)
        let tabs = UUID()
        await navigator.mailTreeAppeared(tabs, isWide: false)
        _ = navigator.takeHandedOffSearchResult()
        // The reader popped in the Search tab: back to the results.
        navigator.searchTabResultChanged(nil)

        navigator.layoutChanged(wasWide: false, isWide: true)
        let resplit = UUID()
        await navigator.mailTreeAppeared(resplit, isWide: true)

        XCTAssertNil(navigator.envelope(in: resplit))
    }

    /// A folder message is not a search result: the Mail tab's own list keeps
    /// it (`FolderListHold`), and the Search tab must not push it.
    func testAFolderMessageIsNotHandedToTheSearchTab() async throws {
        let (navigator, split) = try await readingAResultWide()
        navigator.selectMessage(message, isSearching: false, from: split)

        navigator.layoutChanged(wasWide: true, isWide: false)
        let tabs = UUID()
        await navigator.mailTreeAppeared(tabs, isWide: false)

        XCTAssertNil(navigator.takeHandedOffSearchResult())
    }

}

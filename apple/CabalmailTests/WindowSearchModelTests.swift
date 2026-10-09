import XCTest
import CabalmailKit
@testable import CabalmailUI

/// The window's search model (`SceneNavigator.searchModel`), ported from the
/// process-wide one `AppState` kept. Both layout trees of a window share it,
/// so the query and results survive a layout swap (#1654); each window has
/// its own, so two iPad or Mac windows no longer share one query.
@MainActor
final class WindowSearchModelTests: XCTestCase {
    private var appState: AppState!
    private var preferences: Preferences!

    override func setUp() async throws {
        appState = AppState()
        preferences = Preferences(store: InMemoryPreferenceStore())
    }

    private func makeNavigator() -> SceneNavigator {
        SceneNavigator(coordinator: { nil }, hasClient: { true }, seed: .mail)
    }

    private func search(in navigator: SceneNavigator, client: CabalmailClient) -> MessageListViewModel {
        navigator.searchModel(client: client, preferences: preferences, mailStore: appState.mailStore)
    }

    func testBothTreesOfAWindowGetTheSameModel() throws {
        let navigator = makeNavigator()
        let client = try TestFixtures.makeClient(imap: FakeImapClient())
        let first = search(in: navigator, client: client)
        let second = search(in: navigator, client: client)
        XCTAssertTrue(first === second, "the compact tab and the split must share one instance")
        XCTAssertEqual(first.scope, .search)
    }

    func testANewClientGetsANewModel() throws {
        // A different sign-in must not inherit the previous account's search.
        let navigator = makeNavigator()
        let first = search(in: navigator, client: try TestFixtures.makeClient(imap: FakeImapClient()))
        let second = search(in: navigator, client: try TestFixtures.makeClient(imap: FakeImapClient()))
        XCTAssertFalse(first === second)
    }

    func testEachWindowGetsItsOwnModel() throws {
        let client = try TestFixtures.makeClient(imap: FakeImapClient())
        let first = search(in: makeNavigator(), client: client)
        let second = search(in: makeNavigator(), client: client)
        XCTAssertFalse(first === second, "two windows search separately")
    }
}

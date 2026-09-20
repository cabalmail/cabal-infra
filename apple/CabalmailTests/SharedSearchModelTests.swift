import XCTest
import CabalmailKit
@testable import Cabalmail

/// The search model both iOS layout trees share (#1654): one per client for
/// the life of the process, so the query and results survive a layout swap.
@MainActor
final class SharedSearchModelTests: XCTestCase {

    func testBothTreesGetTheSameModelForTheSameClient() throws {
        let appState = AppState()
        let client = try TestFixtures.makeClient(imap: FakeImapClient())
        let preferences = Preferences(store: InMemoryPreferenceStore())
        let first = appState.sharedSearchModel(client: client, preferences: preferences)
        let second = appState.sharedSearchModel(client: client, preferences: preferences)
        XCTAssertTrue(first === second, "the compact tab and the split must share one instance")
        XCTAssertEqual(first.scope, .search)
    }

    func testANewClientGetsANewModel() throws {
        // A different sign-in must not inherit the previous account's search.
        let appState = AppState()
        let preferences = Preferences(store: InMemoryPreferenceStore())
        let first = appState.sharedSearchModel(
            client: try TestFixtures.makeClient(imap: FakeImapClient()), preferences: preferences
        )
        let second = appState.sharedSearchModel(
            client: try TestFixtures.makeClient(imap: FakeImapClient()), preferences: preferences
        )
        XCTAssertFalse(first === second)
    }
}

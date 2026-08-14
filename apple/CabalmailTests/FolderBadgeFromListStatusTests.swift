import XCTest
import CabalmailKit
@testable import Cabalmail

/// The sidebar badge and the list's Unread chip are the same number shown
/// twice in one window, but only the sidebar's own refresh re-ran STATUS —
/// so a message arriving between sidebar refreshes moved the chip and left
/// the badge on its old value until the user found the second refresh
/// (#1064). The list's refresh already had an authoritative STATUS in hand;
/// it just never published it.
@MainActor
final class FolderBadgeFromListStatusTests: XCTestCase {
    func testAListRefreshPublishesTheFolderCounts() throws {
        let appState = AppState()
        let model = try TestFixtures.makeModel(
            imap: FakeImapClient(),
            envelopes: [],
            appState: appState
        )
        _ = model.applyStatusCounts(
            FolderStatus(messages: 12, unseen: 3, uidValidity: 7, uidNext: 13)
        )
        XCTAssertEqual(model.unseen, 3, "the chip's own count")
        XCTAssertEqual(appState.folderUnreadCounts["INBOX"], 3, "the sidebar badge disagrees with the chip")
        XCTAssertEqual(appState.folderTotalCounts["INBOX"], 12)
    }

    func testTheBadgeIsNotOverwrittenByAStatusWithoutCounts() throws {
        // `unseen` falls back to its prior value rather than flashing 0 when
        // a transient STATUS drops it; the badge must not be handed that
        // guess as if it were a fresh reading.
        let appState = AppState()
        appState.setFolderCounts(folderPath: "INBOX", unread: 4, total: 9)
        let model = try TestFixtures.makeModel(
            imap: FakeImapClient(),
            envelopes: [],
            appState: appState
        )
        _ = model.applyStatusCounts(
            FolderStatus(messages: nil, unseen: nil, uidValidity: 7, uidNext: 13)
        )
        XCTAssertEqual(appState.folderUnreadCounts["INBOX"], 4)
        XCTAssertEqual(appState.folderTotalCounts["INBOX"], 9)
    }

    func testSearchScopeDoesNotPublishAgainstItsSentinelFolder() throws {
        // `.search` resolves to a sentinel folder with an empty path; writing
        // counts under it would put a phantom row in the badge map.
        let appState = AppState()
        let model = MessageListViewModel(
            scope: .search,
            client: try TestFixtures.makeClient(imap: FakeImapClient()),
            preferences: Preferences(store: InMemoryPreferenceStore()),
            appState: appState
        )
        _ = model.applyStatusCounts(
            FolderStatus(messages: 12, unseen: 3, uidValidity: 7, uidNext: 13)
        )
        XCTAssertTrue(appState.folderUnreadCounts.isEmpty)
    }
}

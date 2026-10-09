import XCTest
import CabalmailKit
@testable import CabalmailUI

/// #1796: with the server out of reach, Refresh, a sort change and leaving a
/// search used to empty the message list, and Refresh also deleted the
/// folder's on-disk snapshot, taking the rows from every later offline
/// launch too. Online, each must still start over from the server.
@MainActor
final class OfflineListResetTests: XCTestCase {
    private var fixture: OfflineFolderFixture!

    override func setUp() async throws {
        fixture = OfflineFolderFixture()
    }

    override func tearDown() async throws {
        fixture = nil
    }

    /// An INBOX list opened offline over 22 cached rows and saved counts,
    /// with the launch's own error cleared so each test sees its action's.
    private func offlineInbox() async throws -> (MessageListViewModel, CabalmailClient) {
        let client = try fixture.makeClient(folderState: await fixture.savedState())
        try await fixture.cachedInbox(in: client)
        let model = fixture.makeListModel(client: client)
        await model.loadInitial()
        XCTAssertEqual(model.envelopes.count, 22)
        model.errorMessage = nil
        return (model, client)
    }

    private let subjectOrder = SortCriterion(field: .subject, direction: .ascending)

    func testOfflineRefreshKeepsTheListAndItsSnapshot() async throws {
        let (model, client) = try await offlineInbox()

        await model.hardReload()

        XCTAssertEqual(model.envelopes.count, 22)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertFalse(model.isLoading)
        XCTAssertEqual(model.allCount, 22)
        XCTAssertEqual(model.unseen, 2)
        let snapshot = await client.envelopeCache.snapshot(for: "INBOX")
        XCTAssertEqual(snapshot?.envelopes.count, 22, "the next offline launch still has the rows")
    }

    /// The new order comes from the server, so offline the list keeps its
    /// rows and its order, and the sort goes back to the order shown.
    func testOfflineSortChangeKeepsTheListAndItsOrder() async throws {
        let (model, _) = try await offlineInbox()
        let first = model.envelopes.first?.uid

        await model.window!.setSort(subjectOrder)

        XCTAssertEqual(model.window!.sortCriterion, .default)
        XCTAssertEqual(model.envelopes.count, 22)
        XCTAssertEqual(model.envelopes.first?.uid, first)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertFalse(model.isLoading)
    }

    /// The same while a search or the Unread / Flagged pill is showing: the
    /// shown rows stay rather than being wiped ahead of a search that fails.
    func testOfflineSortChangeDuringASearchKeepsTheList() async throws {
        let (model, _) = try await offlineInbox()
        model.isSearchActive = true

        await model.window!.setSort(subjectOrder)

        XCTAssertEqual(model.envelopes.count, 22)
        XCTAssertEqual(model.window!.sortCriterion, .default)
    }

    /// Leaving a search (or the Unread / Flagged pill) offline falls back to
    /// the folder's cached rows and saved counts instead of an empty list.
    func testLeavingASearchOfflineFallsBackToTheCachedRows() async throws {
        let (model, _) = try await offlineInbox()

        await model.clearSearch()

        XCTAssertEqual(model.envelopes.count, 22)
        XCTAssertEqual(model.allCount, 22)
        XCTAssertEqual(model.unseen, 2)
        XCTAssertEqual(model.flagged, 1)
    }

    /// Under another order the cached rows aren't the top of that order, and
    /// shown as if they were they'd leave gaps once the server answers: only
    /// the counts come back.
    func testLeavingASearchOfflineUnderAnotherOrderRestoresOnlyTheCounts() async throws {
        let (model, _) = try await offlineInbox()
        model.window!.sortCriterion = subjectOrder

        await model.clearSearch()

        XCTAssertTrue(model.envelopes.isEmpty)
        XCTAssertEqual(model.allCount, 22)
        XCTAssertEqual(model.unseen, 2)
    }

    // MARK: - Online

    private func onlineInbox(imap: FakeImapClient = FakeImapClient()) async throws -> MessageListViewModel {
        let fetched = (1...3).map { TestFixtures.makeEnvelope(uid: UInt32($0)) }
        await imap.scriptInitialLoad(
            status: FolderStatus(messages: 3, unseen: 0, uidValidity: 7, uidNext: 4),
            topEnvelopes: fetched
        )
        return try TestFixtures.makeModel(imap: imap, envelopes: [TestFixtures.makeEnvelope(uid: 999)])
    }

    /// Online, Refresh still drops what the list holds and rebuilds from the
    /// server: it is how a stale or leaked row gets purged.
    func testOnlineRefreshStillRebuildsFromTheServer() async throws {
        let model = try await onlineInbox()

        await model.hardReload()

        XCTAssertEqual(Set(model.envelopes.map(\.uid)), [1, 2, 3])
        XCTAssertFalse(model.isLoading)
    }

    func testOnlineSortChangeStillStartsOver() async throws {
        let model = try await onlineInbox()

        await model.window!.setSort(subjectOrder)

        XCTAssertEqual(model.window!.sortCriterion, subjectOrder)
        XCTAssertEqual(Set(model.envelopes.map(\.uid)), [1, 2, 3])
    }

    /// The pick shows at once and the list reads as loading while the server
    /// is asked, so a second pick builds on the first; the later pick does
    /// the reset, and the earlier one stands down when its answer lands.
    func testSortPickShowsAtOnceAndTheLaterPickWins() async throws {
        let imap = FakeImapClient()
        let model = try await onlineInbox(imap: imap)
        await imap.holdNext(.status)

        let first = Task { await model.window!.setSort(SortCriterion(field: .subject, direction: .descending)) }
        await imap.awaitHeld(.status)
        XCTAssertEqual(model.window!.sortCriterion.field, .subject, "shown while the server is asked")
        XCTAssertTrue(model.isLoading)

        await model.window!.setSort(subjectOrder)
        await imap.releaseHeld(.status)
        await first.value

        XCTAssertEqual(model.window!.sortCriterion, subjectOrder)
        XCTAssertEqual(Set(model.envelopes.map(\.uid)), [1, 2, 3])
        XCTAssertFalse(model.isLoading)
    }
}

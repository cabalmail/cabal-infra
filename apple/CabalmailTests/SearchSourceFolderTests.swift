import XCTest
import CabalmailKit
@testable import Cabalmail

// Cross-folder search rows and the mailbox each one belongs to. IMAP UIDs
// are unique only within a folder, so a result set spanning folders can
// hand the client the same UID twice; the index has to survive that and
// still route each row to its own mailbox.
@MainActor
final class SearchSourceFolderTests: XCTestCase {

    // MARK: - The index

    func testDuplicateUIDsAcrossFoldersResolveSeparately() {
        let index = SearchSourceFolderIndex([
            SearchedEnvelope(
                envelope: TestFixtures.makeEnvelope(uid: 1, messageId: "<archive@example.com>"),
                folder: "Archive"
            ),
            SearchedEnvelope(
                envelope: TestFixtures.makeEnvelope(uid: 1, messageId: "<zeta@example.com>"),
                folder: "zeta0802"
            ),
        ])
        XCTAssertEqual(
            index.folder(for: TestFixtures.makeEnvelope(uid: 1, messageId: "<archive@example.com>")),
            "Archive"
        )
        XCTAssertEqual(
            index.folder(for: TestFixtures.makeEnvelope(uid: 1, messageId: "<zeta@example.com>")),
            "zeta0802",
            "the second row keeps its own mailbox rather than inheriting the first row's"
        )
        XCTAssertEqual(
            index.folders(for: TestFixtures.makeEnvelope(uid: 1, messageId: "<zeta@example.com>")),
            ["zeta0802"],
            "rows the key tells apart are not ambiguous on their own"
        )
    }

    func testSameMessageFiledInTwoFoldersResolvesByUID() {
        // The other collision shape: one Message-ID, two folders, two UIDs.
        let index = SearchSourceFolderIndex([
            SearchedEnvelope(
                envelope: TestFixtures.makeEnvelope(uid: 7, messageId: "<copy@example.com>"),
                folder: "Archive"
            ),
            SearchedEnvelope(
                envelope: TestFixtures.makeEnvelope(uid: 12, messageId: "<copy@example.com>"),
                folder: "INBOX"
            ),
        ])
        XCTAssertEqual(
            index.folder(for: TestFixtures.makeEnvelope(uid: 7, messageId: "<copy@example.com>")),
            "Archive"
        )
        XCTAssertEqual(
            index.folder(for: TestFixtures.makeEnvelope(uid: 12, messageId: "<copy@example.com>")),
            "INBOX"
        )
    }

    func testMissingMessageIDFallsBackToTheUIDMap() {
        let index = SearchSourceFolderIndex([
            SearchedEnvelope(envelope: TestFixtures.makeEnvelope(uid: 3), folder: "Archive"),
            SearchedEnvelope(envelope: TestFixtures.makeEnvelope(uid: 3), folder: "zeta0802"),
        ])
        // Nothing tells these two apart, so first-in-server-order wins --
        // best effort, but not a trap -- and the index says there were two,
        // so the bulk guard leaves them alone.
        XCTAssertEqual(index.folder(for: TestFixtures.makeEnvelope(uid: 3)), "Archive")
        XCTAssertEqual(index.folders(for: TestFixtures.makeEnvelope(uid: 3)), ["Archive", "zeta0802"])
        // A row whose Message-ID isn't in the index still resolves by UID.
        XCTAssertEqual(
            index.folder(for: TestFixtures.makeEnvelope(uid: 3, messageId: "<late@example.com>")),
            "Archive"
        )
    }

    func testUnknownRowAndEmptyIndexResolveToNil() {
        XCTAssertTrue(SearchSourceFolderIndex().isEmpty)
        XCTAssertNil(SearchSourceFolderIndex().folder(for: TestFixtures.makeEnvelope(uid: 1)))
        let index = SearchSourceFolderIndex([
            SearchedEnvelope(envelope: TestFixtures.makeEnvelope(uid: 1), folder: "Archive"),
        ])
        XCTAssertNil(index.folder(for: TestFixtures.makeEnvelope(uid: 99)))
    }

    // MARK: - Through the view model

    func testSearchWithCollidingUIDsRoutesEachRowToItsFolder() async throws {
        let imap = FakeImapClient()
        let archived = TestFixtures.makeEnvelope(
            uid: 1, messageId: "<archive@example.com>", subject: "Fixer 843 draft probe"
        )
        let zeta = TestFixtures.makeEnvelope(
            uid: 1, messageId: "<zeta@example.com>", subject: "smtp cutover probe 0726"
        )
        await imap.scriptSearch(SearchResult(
            envelopes: [
                SearchedEnvelope(envelope: archived, folder: "Archive"),
                SearchedEnvelope(envelope: zeta, folder: "zeta0802"),
            ],
            totalEstimate: 2,
            nextCursor: nil,
            foldersSearched: ["Archive", "zeta0802"],
            truncated: false
        ))
        let model = try TestFixtures.makeModel(imap: imap, envelopes: [])
        model.searchQuery = "probe"

        // Before the fix this trapped in Dictionary(uniqueKeysWithValues:)
        // -- "Fatal error: Duplicate values for key: '1'" -- taking the
        // whole app down the instant the results came back.
        await model.runSearch()

        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(model.isSearchActive)
        XCTAssertEqual(model.envelopes.count, 2, "both matches render")
        XCTAssertEqual(model.sourceFolder(for: archived), "Archive")
        XCTAssertEqual(model.sourceFolder(for: zeta), "zeta0802")
    }

    func testClearingASearchDropsTheIndex() async throws {
        let imap = FakeImapClient()
        let hit = TestFixtures.makeEnvelope(uid: 1, messageId: "<archive@example.com>")
        await imap.scriptSearch(SearchResult(
            envelopes: [SearchedEnvelope(envelope: hit, folder: "Archive")],
            totalEstimate: 1,
            nextCursor: nil,
            foldersSearched: ["Archive"],
            truncated: false
        ))
        let model = try TestFixtures.makeModel(imap: imap, envelopes: [])
        model.searchQuery = "probe"
        await model.runSearch()
        XCTAssertEqual(model.sourceFolder(for: hit), "Archive")

        // `clearSearch` runs a folder refresh the fake traps on; the state
        // reset it does first is what this asserts.
        await model.clearSearch()
        XCTAssertTrue(model.sourceFolderIndex.isEmpty)
        XCTAssertEqual(model.sourceFolder(for: hit), "INBOX", "folder mode owns every row again")
    }
    // MARK: - Bulk actions over colliding UIDs

    /// A cross-folder search holding Archive UID 1, zeta0802 UID 1, and an
    /// unambiguous INBOX UID 2. A bare-UID selection of 1 can't say which
    /// of the two rows the user meant.
    private func collidingSearchModel(imap: FakeImapClient) async throws -> MessageListViewModel {
        await imap.scriptSearch(SearchResult(
            envelopes: [
                SearchedEnvelope(
                    envelope: TestFixtures.makeEnvelope(uid: 1, messageId: "<archive@example.com>"),
                    folder: "Archive"
                ),
                SearchedEnvelope(
                    envelope: TestFixtures.makeEnvelope(uid: 1, messageId: "<zeta@example.com>"),
                    folder: "zeta0802"
                ),
                SearchedEnvelope(
                    envelope: TestFixtures.makeEnvelope(uid: 2, messageId: "<inbox@example.com>"),
                    folder: "INBOX"
                ),
            ],
            totalEstimate: 3,
            nextCursor: nil,
            foldersSearched: ["Archive", "zeta0802", "INBOX"],
            truncated: false
        ))
        let model = try TestFixtures.makeModel(imap: imap, envelopes: [])
        model.searchQuery = "probe"
        await model.runSearch()
        XCTAssertEqual(model.envelopes.count, 3)
        return model
    }

    func testBulkSeenSkipsCollidingUIDsAndActsOnTheRest() async throws {
        let imap = FakeImapClient()
        let model = try await collidingSearchModel(imap: imap)

        // Before the fix this trapped in priorFlagState's
        // Dictionary(uniqueKeysWithValues:), and the grouping would have
        // flagged both UID-1 messages.
        await model.setSeen(true, uids: [1, 2])

        let calls = await imap.flagCalls
        XCTAssertEqual(calls.count, 1, "only the unambiguous row reaches the server")
        XCTAssertEqual(calls.first?.folder, "INBOX")
        XCTAssertEqual(calls.first?.uids, [2])
        let collided = model.envelopes.filter { $0.uid == 1 }
        XCTAssertEqual(collided.count, 2)
        XCTAssertTrue(collided.allSatisfy { !$0.flags.contains(.seen) }, "neither UID-1 row changes")
        XCTAssertNotNil(model.skippedNotice, "the user is told why some rows were left alone")
    }

    func testBulkFlagSkipsCollidingUIDs() async throws {
        let imap = FakeImapClient()
        let model = try await collidingSearchModel(imap: imap)

        await model.setFlagged(true, uids: [1])

        let calls = await imap.flagCalls
        XCTAssertTrue(calls.isEmpty)
        XCTAssertTrue(model.envelopes.allSatisfy { !$0.flags.contains(.flagged) })
        XCTAssertNotNil(model.skippedNotice)
    }

    func testBulkMoveSkipsCollidingUIDsAndMovesTheRest() async throws {
        let imap = FakeImapClient()
        let model = try await collidingSearchModel(imap: imap)
        model.selectedUIDs = [1, 2]

        await model.moveMessages(uids: [1, 2], to: "Junk")

        let calls = await imap.moveCalls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.folder, "INBOX")
        XCTAssertEqual(calls.first?.uids, [2])
        XCTAssertEqual(model.envelopes.map(\.uid), [1, 1], "both UID-1 rows stay put")
        XCTAssertEqual(model.selectedUIDs, [1], "the rows left in place stay selected")
        XCTAssertNotNil(model.skippedNotice)
    }

    func testBulkDisposeLeavesCollidingUIDsInPlace() async throws {
        let imap = FakeImapClient()
        let model = try await collidingSearchModel(imap: imap)

        await model.disposeMessages(uids: [1], action: .archive)

        let calls = await imap.moveCalls
        XCTAssertTrue(calls.isEmpty, "Archive UID 1 and zeta0802 UID 1 are both untouched")
        XCTAssertEqual(model.envelopes.count, 3)
    }
}

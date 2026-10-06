import XCTest
import CabalmailKit
@testable import CabalmailUI

// Cross-folder search rows and the mailbox each one belongs to. IMAP UIDs
// are unique only within a folder, so a result set spanning folders can
// hand the client the same UID twice: `Archive` UID 1 next to `zeta0802`
// UID 1 (the #1777 shape). Each row carries its own folder (a `MessageRef`),
// so the selection names exactly the rows picked and every action reaches
// exactly those messages. Before MessageRef a bare-UID selection could not
// say which UID-1 row the user meant, and a guard left both alone.
@MainActor
final class SearchSourceFolderTests: XCTestCase {
    private let archived = MessageRef(folder: "Archive", uid: 1)
    private let zeta = MessageRef(folder: "zeta0802", uid: 1)
    private let inbox = MessageRef(folder: "INBOX", uid: 2)

    // MARK: - Rows carry their folder

    func testSearchWithCollidingUIDsRoutesEachRowToItsFolder() async throws {
        let imap = FakeImapClient()
        let archivedRow = TestFixtures.makeEnvelope(
            uid: 1, messageId: "<archive@example.com>", subject: "Fixer 843 draft probe"
        )
        let zetaRow = TestFixtures.makeEnvelope(
            uid: 1, messageId: "<zeta@example.com>", subject: "smtp cutover probe 0726"
        )
        await imap.scriptSearch(SearchResult(
            envelopes: [
                SearchedEnvelope(envelope: archivedRow, folder: "Archive"),
                SearchedEnvelope(envelope: zetaRow, folder: "zeta0802"),
            ],
            totalEstimate: 2,
            nextCursor: nil,
            foldersSearched: ["Archive", "zeta0802"],
            truncated: false
        ))
        let model = try TestFixtures.makeModel(imap: imap, envelopes: [])
        model.searchQuery = "probe"

        // Before the first fix this trapped in Dictionary(uniqueKeysWithValues:)
        // -- "Fatal error: Duplicate values for key: '1'" -- taking the
        // whole app down the instant the results came back.
        await model.runSearch()

        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(model.isSearchActive)
        XCTAssertEqual(model.envelopes.count, 2, "both matches render")
        XCTAssertEqual(model.envelopes.map { model.rowRef(for: $0) }, [archived, zeta])
        XCTAssertEqual(model.envelopes.map(\.subject), [archivedRow.subject, zetaRow.subject])
    }

    func testClearingASearchHandsTheRowsBackToTheFolder() async throws {
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
        XCTAssertEqual(model.envelopes.map { model.rowRef(for: $0) }, [archived])

        // `clearSearch` runs a folder refresh the fake traps on; the state
        // reset it does first is what this asserts.
        await model.clearSearch()
        XCTAssertFalse(model.isSearchActive)
        XCTAssertTrue(model.envelopes.isEmpty, "no foreign row outlives the search")
    }

    // MARK: - Bulk actions over colliding UIDs

    /// A cross-folder search holding Archive UID 1, zeta0802 UID 1, and
    /// INBOX UID 2.
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

    private func row(_ ref: MessageRef, in model: MessageListViewModel) throws -> Envelope {
        try XCTUnwrap(model.envelope(for: ref))
    }

    func testBulkSeenActsOnExactlyTheSelectedRows() async throws {
        let imap = FakeImapClient()
        let model = try await collidingSearchModel(imap: imap)

        await model.setSeen(true, refs: [archived, inbox])

        let calls = await imap.flagCalls
        XCTAssertEqual(Set(calls.map(\.folder)), ["Archive", "INBOX"])
        XCTAssertEqual(calls.first { $0.folder == "Archive" }?.uids, [1])
        XCTAssertEqual(calls.first { $0.folder == "INBOX" }?.uids, [2])
        XCTAssertTrue(try row(archived, in: model).flags.contains(.seen))
        XCTAssertTrue(try row(inbox, in: model).flags.contains(.seen))
        XCTAssertFalse(
            try row(zeta, in: model).flags.contains(.seen),
            "zeta0802 UID 1 shares the selected row's UID and is left alone"
        )
        XCTAssertNil(model.errorMessage)
    }

    func testBulkFlagReachesOnlyTheChosenOfTwoCollidingRows() async throws {
        let imap = FakeImapClient()
        let model = try await collidingSearchModel(imap: imap)

        await model.setFlagged(true, refs: [zeta])

        let calls = await imap.flagCalls
        XCTAssertEqual(calls.map(\.folder), ["zeta0802"])
        XCTAssertEqual(calls.first?.uids, [1])
        XCTAssertTrue(try row(zeta, in: model).flags.contains(.flagged))
        XCTAssertFalse(try row(archived, in: model).flags.contains(.flagged), "the Archive UID-1 row is not flagged")
    }

    func testBulkMoveMovesExactlyTheSelectedRows() async throws {
        let imap = FakeImapClient()
        let model = try await collidingSearchModel(imap: imap)
        model.selectedRefs = [archived, inbox]

        await model.moveMessages(refs: [archived, inbox], to: "Junk")

        let calls = await imap.moveCalls
        XCTAssertEqual(Set(calls.map(\.folder)), ["Archive", "INBOX"])
        XCTAssertEqual(calls.first { $0.folder == "Archive" }?.uids, [1])
        XCTAssertEqual(calls.first { $0.folder == "INBOX" }?.uids, [2])
        XCTAssertEqual(model.envelopes.map { model.rowRef(for: $0) }, [zeta], "only the row nobody picked stays")
        // The #1792 leftover: a selected UID left behind used to open the
        // other row in the wide reader. Nothing is left selected.
        XCTAssertEqual(model.selectedRefs, [])
    }

    func testBulkDisposeArchivesOnlyTheChosenCopy() async throws {
        let imap = FakeImapClient()
        let model = try await collidingSearchModel(imap: imap)

        await model.disposeMessages(refs: [zeta], action: .archive)

        let calls = await imap.moveCalls
        XCTAssertEqual(calls.map(\.folder), ["zeta0802"])
        XCTAssertEqual(calls.first?.uids, [1])
        XCTAssertEqual(calls.first?.destination, "Archive")
        XCTAssertEqual(model.envelopes.map { model.rowRef(for: $0) }, [archived, inbox], "Archive UID 1 stays listed")
    }

    func testSelectingOneOfTwoCollidingRowsSelectsOnlyIt() async throws {
        let imap = FakeImapClient()
        let model = try await collidingSearchModel(imap: imap)

        model.toggleSelection(try row(zeta, in: model))

        XCTAssertEqual(model.selectedRefs, [zeta], "one tick, one row")
        XCTAssertEqual(model.selectedRefs.count, 1, "the bar counts one message")
        model.selectAllVisible()
        XCTAssertEqual(model.selectedRefs, [archived, zeta, inbox], "select all counts both UID-1 rows")
    }
}

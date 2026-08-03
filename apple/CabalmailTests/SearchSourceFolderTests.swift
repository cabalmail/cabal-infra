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
        // best effort, but not a trap.
        XCTAssertEqual(index.folder(for: TestFixtures.makeEnvelope(uid: 3)), "Archive")
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
}

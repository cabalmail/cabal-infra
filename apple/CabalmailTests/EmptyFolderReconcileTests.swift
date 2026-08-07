import XCTest
import CabalmailKit
@testable import Cabalmail

// Regression tests for #939: a draft deleted server-side stayed in the
// Drafts list indefinitely — the pills read "All, 0" beside the row, and
// opening it 404'd — because `applyRefreshPage` refused to prune against an
// empty fetch under any circumstances. That guard exists so a transient
// blank top page can't wipe a live list, but it also stranded the rows of a
// folder that had legitimately emptied out: nothing to fetch, so nothing
// ever reconciled, through refreshes and relaunches alike. An explicit
// `messages: 0` from STATUS is the corroboration that makes the prune safe;
// a STATUS that merely omits the count still isn't.
@MainActor
final class EmptyFolderReconcileTests: XCTestCase {

    private func makeModel(
        status: FolderStatus,
        loaded: [UInt32]
    ) async throws -> MessageListViewModel {
        let imap = FakeImapClient()
        await imap.scriptInitialLoad(status: status, topEnvelopes: [])
        return try TestFixtures.makeModel(
            imap: imap,
            envelopes: loaded.map { TestFixtures.makeEnvelope(uid: $0) },
            folderPath: "Drafts"
        )
    }

    func testAnEmptyFolderDropsItsStaleRows() async throws {
        let model = try await makeModel(
            status: FolderStatus(messages: 0, unseen: 0, flagged: 0, uidValidity: 7, uidNext: 600),
            loaded: [572]
        )
        await model.refresh()
        XCTAssertEqual(model.totalMessages, 0, "STATUS said the folder is empty")
        XCTAssertTrue(
            model.envelopes.isEmpty,
            "a row the server no longer has can't outlive a STATUS that reports zero messages"
        )
    }

    func testAStatusWithoutACountLeavesTheListAlone() async throws {
        let model = try await makeModel(
            status: FolderStatus(unseen: 0, flagged: 0, uidValidity: 7, uidNext: 600),
            loaded: [572]
        )
        await model.refresh()
        XCTAssertEqual(
            model.envelopes.map(\.uid),
            [572],
            "a STATUS that dropped the message count is not a report of an empty folder"
        )
    }
}

import XCTest
import CabalmailKit
@testable import Cabalmail

// Regression tests for #736: the first visit to a folder runs `loadInitial()`
// inside the view's structured `.task`, which SwiftUI can cancel mid-push
// transition. Because the view only calls `loadInitial()` once per model, a
// cancelled first fetch painted `network("cancelled")` over an empty list
// with nothing left to reload. The load now runs on an unstructured,
// model-owned task (the `refreshFromPull` pattern), so it completes even when
// the caller's task is cancelled. `FakeImapClient` mirrors the production
// transport by failing with `network("cancelled")` when the caller's Task is
// cancelled.
@MainActor
final class MessageListInitialLoadTests: XCTestCase {

    private func makeScriptedImap() async -> FakeImapClient {
        let imap = FakeImapClient()
        await imap.scriptInitialLoad(
            status: FolderStatus(messages: 1, unseen: 1, uidValidity: 7, uidNext: 2),
            topEnvelopes: [TestFixtures.makeEnvelope(uid: 1)]
        )
        return imap
    }

    func testLoadInitialSurvivesCallerTaskCancellation() async throws {
        let imap = await makeScriptedImap()
        let model = try TestFixtures.makeModel(imap: imap, envelopes: [])
        // Cancel before the load body ever runs — the worst-case ordering of
        // the mid-push `.task` cancellation.
        let task = Task { await model.loadInitial() }
        task.cancel()
        await task.value
        XCTAssertNil(model.errorMessage, "a cancelled caller must not paint an error")
        XCTAssertEqual(model.envelopes.map(\.uid), [1], "the first load completes despite the cancel")
    }

    func testLoadInitialPopulatesWithoutCancellation() async throws {
        let imap = await makeScriptedImap()
        let model = try TestFixtures.makeModel(imap: imap, envelopes: [])
        await model.loadInitial()
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.envelopes.map(\.uid), [1])
    }
}

import XCTest
import CabalmailKit
@testable import CabalmailUI

/// Characterization suite for workstream 0.8: how `MessageDetailViewModel`
/// fails to open a message, and how it starts, de-duplicates, retries and
/// abandons a load.
///
/// Protects: the user-facing error copy the reader shows (#940 replaced the
/// raw enum dump with `CabalmailError.localizedDescription`); the #403 load
/// task (owned by the model so SwiftUI's `.task` double-fire can't cancel it,
/// started once per reader by `startLoadIfNeeded()`); and the one rule for a
/// cancel (#1815): a load whose own task is cancelled leaves quietly and
/// un-attempted, whatever it was thrown. The reader has one catch and no
/// retry of its own. The transport retries a spurious URLSession cancel once
/// and reports a cooperative one as `.cancelled`, which the fake mirrors:
/// after a hold it throws `.cancelled` for a cancelled task before it reads
/// its script. The tests that throw a raw `URLError` or `CancellationError`
/// are fake-only (the transport normalizes both away); they pin that the
/// one catch shows whatever arrives on a live task.
@MainActor
final class MessageDetailLoadFailureTests: XCTestCase {
    private var fixture: MessageDetailLoadFixture!
    private let uid: UInt32 = 7

    override func setUp() async throws {
        fixture = MessageDetailLoadFixture()
    }

    override func tearDown() async throws {
        fixture.cleanUp()
        fixture = nil
    }

    /// A reader on INBOX/7 with a snapshotted folder and `bodies` scripted
    /// for its opens, in order.
    private func makeReader(bodies: [Result<Data, Error>]) async throws -> (MessageDetailViewModel, FakeImapClient) {
        let imap = FakeImapClient()
        await imap.scriptBody(folder: "INBOX", uid: uid, bodies)
        let model = try await fixture.makeReader(imap: imap, uid: uid)
        try await fixture.seedSnapshot(model)
        return (model, imap)
    }

    /// The failed-open screen: no body, the message, the spinner gone and the
    /// attempt counted (so the view shows the error and Retry).
    private func assertFailedOpen(
        _ model: MessageDetailViewModel,
        message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(model.errorMessage, message, file: file, line: line)
        XCTAssertNil(model.plainText, file: file, line: line)
        XCTAssertNil(model.htmlBody, file: file, line: line)
        XCTAssertTrue(model.attachments.isEmpty, file: file, line: line)
        XCTAssertFalse(model.isLoading, file: file, line: line)
        XCTAssertTrue(model.hasAttemptedLoad, file: file, line: line)
    }

    // MARK: - Error copy

    func testAMessageGoneFromTheFolderShowsTheServersSentence() async throws {
        let body = #"{"status": "That message is no longer in INBOX", "folder": "INBOX", "id": 7}"#
        let (model, imap) = try await makeReader(bodies: [.failure(CabalmailError.server(code: "404", message: body))])

        await model.load()

        assertFailedOpen(model, message: "That message is no longer in INBOX.")
        let fetches = await imap.fetchBodyCalls
        XCTAssertEqual(fetches.count, 1, "no retry")
    }

    func testAMissingPresignedURLShowsTheDecodingCopy() async throws {
        let error = CabalmailError.decoding("fetch_message returned no presigned URL")
        let (model, _) = try await makeReader(bodies: [.failure(error)])

        await model.load()

        assertFailedOpen(model, message: "Couldn't read the server's reply. fetch_message returned no presigned URL.")
    }

    func testMaintenanceShowsTheMaintenanceMessage() async throws {
        let copy = "Cabalmail is being updated. Try again in a few minutes."
        let (model, _) = try await makeReader(bodies: [.failure(CabalmailError.maintenance(message: copy))])

        await model.load()

        assertFailedOpen(model, message: copy)
    }

    /// A spurious URLSession cancel that failed its retry in the transport
    /// reaches the reader as `.network("cancelled")` on a live task, and is
    /// shown like any network failure, with no second retry here.
    func testANetworkCancelledErrorShowsCouldNotReachTheServer() async throws {
        let (model, imap) = try await makeReader(bodies: [.failure(CabalmailError.network("cancelled"))])

        await model.load()

        assertFailedOpen(model, message: "Couldn't reach the server. cancelled.")
        let fetches = await imap.fetchBodyCalls
        XCTAssertEqual(fetches.count, 1, "no retry for the normalized error")
    }

    /// A load whose task is cancelled mid-fetch leaves quietly, un-attempted,
    /// so the view keeps its spinner for the next live task (#1815). Before,
    /// the cancel arrived as `.network("cancelled")` and painted "Couldn't
    /// reach the server. cancelled." with Retry. Latent until something
    /// cancels the reader's load task; nothing in the view does today.
    func testCancellingTheLoadTaskMidFetchLeavesQuietlyUnattempted() async throws {
        let (model, imap) = try await makeReader(bodies: [.success(MessageDetailMimeFixture.alternative)])
        await imap.holdNext(.fetchBody)

        let load = Task { await model.load() }
        guard try await MessageDetailLoadFixture.awaitHeld(.fetchBody, in: imap) else { return }
        load.cancel()
        await imap.releaseHeld(.fetchBody)
        await load.value

        XCTAssertFalse(model.hasAttemptedLoad, "left un-attempted, so the view keeps its spinner")
        XCTAssertFalse(model.isLoading)
        XCTAssertNil(model.errorMessage)
        XCTAssertNil(model.plainText)
        let fetches = await imap.fetchBodyCalls
        XCTAssertEqual(fetches.count, 1, "no retry of a cancelled load")
    }

    func testARawDecodingErrorShowsItsLocalizedDescription() async throws {
        let decodingError: Error
        do {
            _ = try JSONDecoder().decode([String: String].self, from: Data("not json".utf8))
            return XCTFail("the fixture must fail to decode")
        } catch {
            decodingError = error
        }
        XCTAssertTrue(decodingError is DecodingError)
        let (model, _) = try await makeReader(bodies: [.failure(decodingError)])

        await model.load()

        assertFailedOpen(model, message: decodingError.localizedDescription)
    }

    // MARK: - What arrives on a live task is shown, once

    /// `.cancelled` on a live task is shown, not swallowed: the reader's
    /// guard is its own task, not the error's case. (The transport throws
    /// `.cancelled` only for a cancelled task, so this is fake-only.)
    func testACancelledErrorOnALiveTaskIsShown() async throws {
        let (model, imap) = try await makeReader(bodies: [.failure(CabalmailError.cancelled)])

        await model.load()

        assertFailedOpen(model, message: "That request was cancelled.")
        let fetches = await imap.fetchBodyCalls
        XCTAssertEqual(fetches.count, 1)
    }

    /// Fake-only: a raw `URLError.cancelled` is shown with its own text and
    /// not retried. The one retry of a spurious cancel is the transport's.
    func testFakeOnlyURLErrorCancelledIsShownWithoutARetry() async throws {
        let (model, imap) = try await makeReader(bodies: [
            .failure(URLError(.cancelled)),
            .success(MessageDetailMimeFixture.alternative),
        ])

        await model.load()

        assertFailedOpen(model, message: URLError(.cancelled).localizedDescription)
        let fetches = await imap.fetchBodyCalls
        XCTAssertEqual(fetches.count, 1, "the reader has no retry of its own")
    }

    func testFakeOnlyOtherURLErrorShowsItsLocalizedDescriptionWithoutARetry() async throws {
        let (model, imap) = try await makeReader(bodies: [.failure(URLError(.timedOut))])

        await model.load()

        assertFailedOpen(model, message: URLError(.timedOut).localizedDescription)
        let fetches = await imap.fetchBodyCalls
        XCTAssertEqual(fetches.count, 1)
    }

    /// Fake-only: a `CancellationError` on a live task is shown with its own
    /// text, like any other error, and not retried.
    func testFakeOnlyCancellationErrorOnALiveTaskIsShownWithoutARetry() async throws {
        let (model, imap) = try await makeReader(bodies: [.failure(CancellationError())])

        await model.load()

        assertFailedOpen(model, message: CancellationError().localizedDescription)
        let fetches = await imap.fetchBodyCalls
        XCTAssertEqual(fetches.count, 1)
    }

    // MARK: - Retry and cancellation

    func testRetryAfterAFailureClearsTheErrorWhileLoadingAndThenRenders() async throws {
        let (model, imap) = try await makeReader(bodies: [
            .failure(CabalmailError.network("offline")),
            .success(MessageDetailMimeFixture.alternative),
        ])
        await model.load()
        assertFailedOpen(model, message: "Couldn't reach the server. offline.")

        // The Retry button is a plain `await model.load()`.
        await imap.holdNext(.fetchBody)
        let retry = Task { await model.load() }
        guard try await MessageDetailLoadFixture.awaitHeld(.fetchBody, in: imap, calls: 2) else { return }
        XCTAssertNil(model.errorMessage, "cleared as the retry starts")
        XCTAssertTrue(model.isLoading)
        XCTAssertTrue(model.hasAttemptedLoad, "still set from the first attempt")
        await imap.releaseHeld(.fetchBody)
        await retry.value

        XCTAssertEqual(model.plainText, MessageDetailMimeFixture.alternativePlain)
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.isLoading)
        let fetches = await imap.fetchBodyCalls
        XCTAssertEqual(fetches.count, 2)
    }

    func testALoadWhoseTaskIsCancelledBeforeItStartsDoesNothing() async throws {
        let (model, imap) = try await makeReader(bodies: [.success(MessageDetailMimeFixture.alternative)])

        // On the main actor the task can't start before it is cancelled.
        let load = Task { await model.load() }
        load.cancel()
        await load.value

        XCTAssertFalse(model.hasAttemptedLoad, "left un-attempted, so the view keeps its spinner")
        XCTAssertFalse(model.isLoading)
        XCTAssertNil(model.errorMessage)
        XCTAssertNil(model.plainText)
        let fetches = await imap.fetchBodyCalls
        XCTAssertTrue(fetches.isEmpty)
    }

    // MARK: - startLoadIfNeeded

    func testStartLoadIfNeededRunsOneLoadPerReader() async throws {
        let (model, imap) = try await makeReader(bodies: [.success(MessageDetailMimeFixture.alternative)])
        await imap.holdNext(.fetchBody)

        // The second call lands before the first load has even started
        // (`isLoading` is still false), so only the load task stops it.
        model.startLoadIfNeeded()
        model.startLoadIfNeeded()
        guard try await MessageDetailLoadFixture.awaitHeld(.fetchBody, in: imap) else { return }
        XCTAssertTrue(model.isLoading)
        XCTAssertFalse(model.hasAttemptedLoad)
        model.startLoadIfNeeded()
        await imap.releaseHeld(.fetchBody)
        try await waitUntilOnMainActor { model.hasAttemptedLoad }

        XCTAssertEqual(model.plainText, MessageDetailMimeFixture.alternativePlain)
        XCTAssertNil(model.errorMessage)
        // Once a body is showing, a later appearance doesn't load again.
        model.startLoadIfNeeded()
        await MessageDetailLoadFixture.drainMainActor()
        XCTAssertFalse(model.isLoading)
        let fetches = await imap.fetchBodyCalls
        XCTAssertEqual(fetches.count, 1)
    }

    /// After a failed load, a later `startLoadIfNeeded()` (the view appearing
    /// again) fetches again rather than leaving the error until Retry is
    /// tapped (#1815): the load task is cleared when it finishes. Before, the
    /// finished task, which is never `isCancelled`, blocked every later start.
    /// Once a load has succeeded, appearing again fetches nothing.
    func testStartLoadIfNeededAfterAFailedAttemptLoadsAgain() async throws {
        let (model, imap) = try await makeReader(bodies: [
            .failure(CabalmailError.network("offline")),
            .success(MessageDetailMimeFixture.alternative),
        ])
        model.startLoadIfNeeded()
        try await waitUntilOnMainActor { model.hasAttemptedLoad }
        assertFailedOpen(model, message: "Couldn't reach the server. offline.")

        model.startLoadIfNeeded()
        try await waitUntilOnMainActor { model.plainText != nil }

        XCTAssertEqual(model.plainText, MessageDetailMimeFixture.alternativePlain)
        XCTAssertNil(model.errorMessage)
        let afterAppear = await imap.fetchBodyCalls
        XCTAssertEqual(afterAppear.count, 2)

        model.startLoadIfNeeded()
        await MessageDetailLoadFixture.drainMainActor()
        let afterLoaded = await imap.fetchBodyCalls
        XCTAssertEqual(afterLoaded.count, 2, "a loaded reader does not fetch again")
    }
}

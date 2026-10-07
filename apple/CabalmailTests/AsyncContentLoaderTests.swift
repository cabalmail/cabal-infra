import XCTest
import CabalmailKit
@testable import CabalmailUI

/// `AsyncContentLoader`, the three states behind the message-source sheet,
/// the Move to Folder sheet and the notification folder picker (#1908).
///
/// A load whose own task is cancelled (the sheet dismissed, the picker rebuilt
/// mid-push with its state kept) paints nothing and leaves the spinner for the
/// next `.task`; before, it put "…: Couldn't reach the server. cancelled." up
/// with Retry, and in the picker could land over the list the next load had
/// fetched. The first two tests drive the source sheet's real path, a reader's
/// `rawSourceBytes()` over `FakeImapClient`, whose held fetch fails as cancelled
/// when its task is.
@MainActor
final class AsyncContentLoaderTests: XCTestCase {
    private var fixture: MessageDetailLoadFixture!
    private let uid: UInt32 = 7

    override func setUp() async throws {
        fixture = MessageDetailLoadFixture()
    }

    override func tearDown() async throws {
        fixture.cleanUp()
        fixture = nil
    }

    // MARK: - Cancelled loads

    func testACancelledLoadPaintsNoErrorAndKeepsTheSpinner() async throws {
        let (model, imap) = try await makeReader(bodies: [.success(MessageDetailMimeFixture.alternative)])
        let loader = AsyncContentLoader<String>()

        let load = try await startCancelledLoad(loader, model: model, imap: imap)
        await imap.releaseHeld(.fetchBody)
        await load.value

        XCTAssertNil(loader.errorMessage)
        XCTAssertTrue(loader.isLoading, "the spinner stays for the next appearance's load")
        XCTAssertNil(loader.value)
    }

    /// The picker's race: the next appearance's load finishes first, then the
    /// cancelled one lands and must not cover its answer.
    func testACancelledLoadLandingLateDoesNotCoverTheNextLoadsAnswer() async throws {
        let (model, imap) = try await makeReader(bodies: [.success(MessageDetailMimeFixture.alternative)])
        let loader = AsyncContentLoader<String>()
        let cancelled = try await startCancelledLoad(loader, model: model, imap: imap)

        await loadSource(loader, model: model)
        let expected = MessageSource.decode(MessageDetailMimeFixture.alternative)
        XCTAssertEqual(loader.value, expected)
        await imap.releaseHeld(.fetchBody)
        await cancelled.value

        XCTAssertEqual(loader.value, expected)
        XCTAssertNil(loader.errorMessage)
        XCTAssertFalse(loader.isLoading)
    }

    func testAnAnswerFetchedBeforeTheCancelIsStillShown() async throws {
        let loader = AsyncContentLoader<String>()

        let load = Task { await loader.load({ "answer" }, failure: { _ in "failed" }) }
        load.cancel()
        await load.value

        XCTAssertEqual(loader.value, "answer")
        XCTAssertFalse(loader.isLoading)
        XCTAssertNil(loader.errorMessage)
    }

    // MARK: - Live loads

    func testARealFailureIsStillShownForRetry() async throws {
        let failure = CabalmailError.network("The request timed out.")
        let (model, _) = try await makeReader(bodies: [.failure(failure)])
        let loader = AsyncContentLoader<String>()

        await loadSource(loader, model: model)

        XCTAssertEqual(
            loader.errorMessage,
            "Couldn't load message source: Couldn't reach the server. The request timed out."
        )
        XCTAssertFalse(loader.isLoading)
        XCTAssertNil(loader.value)
    }

    /// Read off the task, not the error: a cancel-shaped error on a live task
    /// is shown, so the spinner can't be stranded.
    func testACancelShapedErrorOnALiveTaskIsStillShown() async {
        let loader = AsyncContentLoader<String>()

        await loader.load({ throw CabalmailError.cancelled }, failure: { "Couldn't load: \($0.localizedDescription)" })

        XCTAssertEqual(loader.errorMessage, "Couldn't load: That request was cancelled.")
        XCTAssertFalse(loader.isLoading)
    }

    /// Two live loads overlapping (a Retry still out when the next appearance
    /// loads): the one that answers last wins, and an answer clears the
    /// other's error.
    func testALaterAnswerClearsAnOverlappingLiveFailure() async throws {
        let loader = AsyncContentLoader<String>()
        let failing = Gate()
        let answering = Gate()
        let first = Task {
            await loader.load(
                { await failing.pass(); throw CabalmailError.network("offline") },
                failure: { _ in "failed" }
            )
        }
        let second = Task {
            await loader.load({ await answering.pass(); return "answer" }, failure: { _ in "failed" })
        }
        try await waitUntil { await failing.isWaiting }
        try await waitUntil { await answering.isWaiting }

        await failing.open()
        await first.value
        XCTAssertEqual(loader.errorMessage, "failed")
        await answering.open()
        await second.value

        XCTAssertEqual(loader.value, "answer")
        XCTAssertNil(loader.errorMessage)
        XCTAssertFalse(loader.isLoading)
    }

    func testFailShowsTheMessageWithoutLoading() {
        let loader = AsyncContentLoader<[Folder]>()

        loader.fail("Sign in to load folders.")

        XCTAssertEqual(loader.errorMessage, "Sign in to load folders.")
        XCTAssertFalse(loader.isLoading)
        XCTAssertNil(loader.value)
    }

    // MARK: - Helpers

    private func makeReader(
        bodies: [Result<Data, Error>]
    ) async throws -> (MessageDetailViewModel, FakeImapClient) {
        let imap = FakeImapClient()
        await imap.scriptBody(folder: "INBOX", uid: uid, bodies)
        let model = try await fixture.makeReader(imap: imap, uid: uid)
        try await fixture.seedSnapshot(model)
        return (model, imap)
    }

    /// The source sheet's own call.
    private func loadSource(_ loader: AsyncContentLoader<String>, model: MessageDetailViewModel) async {
        await loader.load(
            { try await MessageSource.decode(model.rawSourceBytes()) },
            failure: { "Couldn't load message source: \($0.localizedDescription)" }
        )
    }

    /// Starts the sheet's load and cancels it while its fetch is held.
    private func startCancelledLoad(
        _ loader: AsyncContentLoader<String>,
        model: MessageDetailViewModel,
        imap: FakeImapClient
    ) async throws -> Task<Void, Never> {
        await imap.holdNext(.fetchBody)
        let load = Task { await loadSource(loader, model: model) }
        let held = try await MessageDetailLoadFixture.awaitHeld(.fetchBody, in: imap)
        XCTAssertTrue(held, "the fetch never arrived")
        load.cancel()
        return load
    }
}

/// Parks `pass()` until `open()`.
private actor Gate {
    private var waiter: CheckedContinuation<Void, Never>?
    private var opened = false

    var isWaiting: Bool { waiter != nil }

    func pass() async {
        guard !opened else { return }
        await withCheckedContinuation { waiter = $0 }
    }

    func open() {
        opened = true
        waiter?.resume()
        waiter = nil
    }
}

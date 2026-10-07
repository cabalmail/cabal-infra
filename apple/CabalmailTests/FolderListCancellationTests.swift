import XCTest
import CabalmailKit
@testable import CabalmailUI

/// A folder-list load whose own task is cancelled is no outcome (#1908).
///
/// On iPhone the sidebar is on screen first and the launch pushes INBOX over
/// it straight away, which cancels the sidebar's `.task` while `/list_folders`
/// is in flight. The cancelled request used to land as an error: with a saved
/// list, `foldersForDisplay` drew that copy under "Couldn't reach the server.
/// cancelled."; with none (the first launch after a sign-in), an empty sidebar
/// kept that line until a pull-to-refresh, because the view only loads when it
/// has no model. Now a cut-short load writes nothing, records no attempt, and
/// the next appearance loads again (`reloadIfCutShort`). These drive the real
/// API-backed client, so the cancel goes through the same `shouldQueue`
/// fallback the app's does.
@MainActor
final class FolderListCancellationTests: XCTestCase {
    private var fixture: OfflineFolderFixture!

    override func setUp() async throws {
        fixture = OfflineFolderFixture()
    }

    override func tearDown() async throws {
        fixture = nil
    }

    // MARK: - A cut-short load is no outcome

    func testACutShortLoadWithNothingSavedPaintsNoError() async throws {
        let world = try await makeWorld(folderState: FolderStateCache())
        let model = world.model
        let wire = world.wire

        try await cutShort(wire) { await model.loadFolderList() }

        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(model.folders.isEmpty)
    }

    func testACutShortLoadDoesNotDrawTheSavedCopy() async throws {
        let world = try await makeWorld(folderState: await fixture.savedState())
        let model = world.model
        let wire = world.wire
        let appState = world.appState

        try await cutShort(wire) { await model.loadFolderList() }

        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.isShowingSavedCopy)
        XCTAssertTrue(model.folders.isEmpty)
        XCTAssertEqual(appState.mailStore.counts.savedFolderCounts.seededPaths, [], "no saved badges were seeded")
        XCTAssertNil(appState.mailStore.counts.subscribedFolderPaths, "nothing was published to the session")
        XCTAssertTrue(appState.mailStore.counts.folderUnreadCounts.isEmpty)
    }

    /// The cancel's shape before #1907 (the transport's `.network`) is read
    /// the same way: off the task, not the error.
    func testACancelThatReadsAsANetworkErrorIsQuietToo() async throws {
        let world = try await makeWorld(folderState: await fixture.savedState(), cancelError: .network("cancelled"))
        let model = world.model
        let wire = world.wire

        try await cutShort(wire) { await model.loadFolderList() }

        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.isShowingSavedCopy)
    }

    func testACutShortLoadRecordsNoAttemptAndKeepsItsSpinner() async throws {
        let world = try await makeWorld(folderState: FolderStateCache())
        let model = world.model
        let wire = world.wire

        try await cutShort(wire) { await model.loadFolderList() }

        XCTAssertFalse(model.hasAttemptedLoad)
        XCTAssertTrue(model.isLoading, "the spinner holds for the next appearance")
    }

    func testAListThatAnsweredBeforeTheCancelIsApplied() async throws {
        let world = try await makeWorld(folderState: FolderStateCache())
        let model = world.model
        let wire = world.wire
        await wire.answerAfterCancellation()

        try await cutShort(wire) { await model.loadFolderList() }

        XCTAssertEqual(Set(model.folders.map(\.path)), ["INBOX", "Archive", "Projects"])
        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(model.hasAttemptedLoad)
        XCTAssertFalse(model.isLoading)
    }

    /// A refresh cut short over a live list keeps the list on screen: before,
    /// `foldersForDisplay` fell back to the list the live load had just saved
    /// and the error went up over it.
    func testACutShortRefreshKeepsWhatIsOnScreen() async throws {
        let world = try await makeWorld(folderState: FolderStateCache())
        let model = world.model
        let wire = world.wire
        await model.loadFolderList()

        try await cutShort(wire) { await model.refresh() }

        XCTAssertEqual(Set(model.folders.map(\.path)), ["INBOX", "Archive", "Projects"])
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.isShowingSavedCopy)
        XCTAssertFalse(model.isLoading)
    }

    // MARK: - The next appearance

    func testTheNextAppearanceLoadsTheLiveList() async throws {
        let world = try await makeWorld(folderState: await fixture.savedState())
        let model = world.model
        let wire = world.wire
        let appState = world.appState
        try await cutShort(wire) { await model.loadFolderList() }

        await model.reloadIfCutShort()

        XCTAssertEqual(Set(model.folders.map(\.path)), ["INBOX", "Archive", "Projects"])
        XCTAssertFalse(model.isShowingSavedCopy)
        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(model.hasAttemptedLoad)
        XCTAssertFalse(model.isLoading)
        XCTAssertEqual(appState.mailStore.counts.folderUnreadCounts["INBOX"], 4, "counted live")
        let calls = await wire.listCalls
        XCTAssertEqual(calls, 2)
    }

    func testAnAppearanceAfterAnOutcomeDoesNotReload() async throws {
        let liveWorld = try await makeWorld(folderState: FolderStateCache())
        let live = liveWorld.model
        let liveWire = liveWorld.wire
        await live.loadFolderList()
        await live.reloadIfCutShort()
        let liveCalls = await liveWire.listCalls
        XCTAssertEqual(liveCalls, 1, "a loaded sidebar isn't refetched on every appearance")

        let offlineWorld = try await makeWorld(folderState: await fixture.savedState())
        let offline = offlineWorld.model
        let offlineWire = offlineWorld.wire
        await offlineWire.failNext(.network("The Internet connection appears to be offline."))
        await offline.loadFolderList()
        await offline.reloadIfCutShort()
        let offlineCalls = await offlineWire.listCalls
        XCTAssertEqual(offlineCalls, 1, "an outage is an outcome; reconnecting reloads it, not appearing")
        XCTAssertTrue(offline.isShowingSavedCopy)
    }

    /// The next appearance's load finishes while the cancelled one is still
    /// out: when the cancelled one lands, it changes nothing.
    func testACancelledLoadLandingAfterTheNextOneChangesNothing() async throws {
        let world = try await makeWorld(folderState: await fixture.savedState())
        let model = world.model
        let wire = world.wire
        await wire.holdNext()
        let firstLoad = Task { await model.loadFolderList() }
        try await waitUntil { await wire.isHolding }
        firstLoad.cancel()

        await model.reloadIfCutShort()
        await wire.release()
        await firstLoad.value

        XCTAssertEqual(Set(model.folders.map(\.path)), ["INBOX", "Archive", "Projects"])
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.isShowingSavedCopy)
        XCTAssertFalse(model.isLoading)
        let calls = await wire.listCalls
        XCTAssertEqual(calls, 2)
    }

    // MARK: - Real failures are still shown

    func testARealOutageStillDrawsTheSavedCopyAndEndsTheAttempt() async throws {
        let world = try await makeWorld(folderState: await fixture.savedState())
        let model = world.model
        let wire = world.wire
        await wire.failNext(.network("The Internet connection appears to be offline."))

        await model.loadFolderList()

        XCTAssertTrue(model.isShowingSavedCopy)
        let message = try XCTUnwrap(model.errorMessage)
        XCTAssertTrue(message.contains("Couldn't reach the server"), message)
        XCTAssertTrue(model.hasAttemptedLoad)
        XCTAssertFalse(model.isLoading)
    }

    func testAServerErrorIsStillShown() async throws {
        let world = try await makeWorld(folderState: FolderStateCache())
        let model = world.model
        let wire = world.wire
        await wire.failNext(.server(code: "500", message: ""))

        await model.loadFolderList()

        XCTAssertEqual(model.errorMessage, "The server couldn't complete that request (500).")
        XCTAssertTrue(model.hasAttemptedLoad)
        XCTAssertFalse(model.isLoading)
    }

    // MARK: - Helpers

    /// A sidebar model, the wire under it and the session state it publishes to.
    private struct World {
        let model: FolderListViewModel
        let wire: HeldFolderTransport
        let appState: AppState
    }

    private func makeWorld(
        folderState: FolderStateCache,
        cancelError: CabalmailError = .cancelled
    ) async throws -> World {
        let wire = HeldFolderTransport(cancelError: cancelError)
        let appState = AppState()
        let client = try fixture.makeClient(folderState: folderState, transport: wire)
        let model = FolderListViewModel(client: client, mailStore: appState.mailStore)
        return World(model: model, wire: wire, appState: appState)
    }

    /// Runs `load` in a task that is cancelled while `/list_folders` is out,
    /// the way SwiftUI cancels the sidebar's `.task`.
    private func cutShort(_ wire: HeldFolderTransport, _ load: @escaping @MainActor () async -> Void) async throws {
        await wire.holdNext()
        let task = Task { await load() }
        try await waitUntil { await wire.isHolding }
        task.cancel()
        await wire.release()
        await task.value
    }
}

/// `/list_folders` and `/folder_status` as `FolderServerTransport` answers
/// them, except that the next `/list_folders` can be held, and a request whose
/// task is cancelled fails the way URLSession fails it.
private actor HeldFolderTransport: HTTPTransport {
    private let cancelError: CabalmailError
    private var holdArmed = false
    private var held: CheckedContinuation<Void, Never>?
    private var failure: CabalmailError?
    private var answersAfterCancellation = false
    private(set) var listCalls = 0

    init(cancelError: CabalmailError) {
        self.cancelError = cancelError
    }

    var isHolding: Bool { held != nil }

    func holdNext() { holdArmed = true }
    func failNext(_ error: CabalmailError) { failure = error }
    func answerAfterCancellation() { answersAfterCancellation = true }

    func release() {
        held?.resume()
        held = nil
    }

    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if request.url?.path.hasSuffix("/list_folders") == true {
            listCalls += 1
            if holdArmed {
                holdArmed = false
                await withCheckedContinuation { held = $0 }
            }
            if let failure {
                self.failure = nil
                throw failure
            }
        }
        if Task.isCancelled, !answersAfterCancellation { throw cancelError }
        return try await FolderServerTransport().perform(request)
    }
}

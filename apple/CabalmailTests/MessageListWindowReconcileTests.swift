import XCTest
import CabalmailKit
@testable import CabalmailUI

/// The loaded window has to stay lined up with the server's positions when
/// the folder changes elsewhere (#1817, #1818). Each test drives a real
/// `MessageListViewModel` against `ServerFolder`, a folder that answers
/// STATUS and positional pages from one list of UIDs, so the assertion is
/// always the same: every loaded index holds the UID the server has there.
@MainActor
final class MessageListWindowReconcileTests: XCTestCase {

    // MARK: - #1817: a removal made elsewhere under a paginated window

    func testARemovalElsewhereLeavesAPaginatedWindowAndTheNextPageSkipsNothing() async throws {
        let world = try await World.opened(size: 400, pages: 1)
        XCTAssertEqual(world.model.envelopes.count, 250)
        let topsBefore = await world.server.topCalls.count
        await world.server.remove(330)

        await world.model.refresh()

        let pages = await world.server.pageCalls
        let tops = await world.server.topCalls.count
        XCTAssertEqual(pages.last, Page(offset: 0, limit: 250), "one read of the window's reach")
        XCTAssertEqual(tops, topsBefore, "which stands in for the top page")
        XCTAssertFalse(world.model.envelopes.contains { $0.uid == 330 })
        try await world.assertAligned()

        world.model.ensureLoaded(around: 249)
        await world.model.loadMoreTask?.value
        XCTAssertEqual(world.model.envelopes.count, 399, "the next page loads the rest of the folder")
        try await world.assertAligned()
        XCTAssertTrue(world.model.envelopes.contains { $0.uid == 150 }, "the row at the old page boundary is loaded")
    }

    func testARowRemovedElsewhereLeavesBothCachesAndStaysGoneOnTheNextOpen() async throws {
        let world = try await World.opened(size: 400, pages: 1)
        await world.persistSnapshot()
        try await world.client.bodyCache.store(folder: "INBOX", uidValidity: 7, uid: 330, bytes: Data("x".utf8))
        let before = try await world.snapshotUIDs()
        XCTAssertTrue(before.contains(330), "the row starts out on disk")
        await world.server.remove(330)

        await world.model.refresh()

        let after = try await world.snapshotUIDs()
        XCTAssertFalse(after.contains(330))
        let body = await world.client.bodyCache.fetch(folder: "INBOX", uidValidity: 7, uid: 330)
        XCTAssertNil(body)

        // Reopened offline: the snapshot is all there is, and the row is
        // not in it.
        await world.server.setOffline(true)
        let reopened = world.makeModel()
        await reopened.loadInitial()
        XCTAssertEqual(reopened.envelopes.count, 250, "the read's rows, which replaced 330 with 150")
        XCTAssertFalse(reopened.envelopes.contains { $0.uid == 330 })
    }

    func testAWindowWiderThanOnePageIsReadAcrossPagesAndProvesTheRowGone() async throws {
        let world = try await World.opened(size: 600, pages: 2)
        XCTAssertEqual(world.model.envelopes.count, 450)
        await world.persistSnapshot()
        await world.server.remove(500)

        await world.model.refresh()

        let pages = await world.server.pageCalls
        XCTAssertEqual(Array(pages.suffix(2)), [Page(offset: 0, limit: 250), Page(offset: 249, limit: 201)],
                       "two pages sharing one row at the seam")
        try await world.assertAligned()
        let cached = try await world.snapshotUIDs()
        XCTAssertFalse(cached.contains(500))
    }

    func testAFolderEmptiedElsewhereEmptiesAPaginatedWindow() async throws {
        let world = try await World.opened(size: 400, pages: 1)
        await world.server.removeAll()

        await world.model.refresh()

        XCTAssertTrue(world.model.envelopes.isEmpty)
        XCTAssertEqual(world.model.totalMessages, 0)
    }

    // MARK: - The common cases cost nothing extra

    func testNewMailOnTopOfAPaginatedWindowTakesOnlyTheTopPage() async throws {
        let world = try await World.opened(size: 400, pages: 1)
        let pagesBefore = await world.server.pageCalls.count
        await world.server.arrive(3)

        await world.model.refresh()
        await world.model.refresh()

        let pages = await world.server.pageCalls
        XCTAssertEqual(pages.count, pagesBefore, "no positional read for mail that lands in the top page")
        XCTAssertEqual(world.model.envelopes.count, 253)
        try await world.assertAligned()
    }

    func testThisListsOwnMoveIsNotReadAsAChangeElsewhere() async throws {
        let world = try await World.opened(size: 400, pages: 1)
        let pagesBefore = await world.server.pageCalls.count
        let row = try XCTUnwrap(world.model.envelopes.first { $0.uid == 300 })

        await world.model.moveTo(row, destination: "Archive")
        await world.model.refresh()

        let pages = await world.server.pageCalls
        XCTAssertEqual(pages.count, pagesBefore)
        XCTAssertEqual(world.model.envelopes.count, 249)
        try await world.assertAligned()
    }

    // MARK: - When a re-read waits or gives up

    func testARefreshThatMayPredateARemovalLeavesTheWindowForTheNextOne() async throws {
        let world = try await World.opened(size: 400, pages: 1)
        let pagesBefore = await world.server.pageCalls.count
        await world.server.remove(330)
        world.model.pendingRemovedRefs.insert(MessageRef(folder: "INBOX", uid: 399))

        await world.model.refresh()
        let pagesDuring = await world.server.pageCalls.count
        XCTAssertEqual(pagesDuring, pagesBefore, "a reply that may count a removal in flight proves nothing")

        world.model.pendingRemovedRefs.remove(MessageRef(folder: "INBOX", uid: 399))
        await world.model.refresh()
        XCTAssertFalse(world.model.envelopes.contains { $0.uid == 330 })
        try await world.assertAligned()
    }

    func testARemovalThatStartsWhileTheReadIsOutAbandonsIt() async throws {
        let world = try await World.opened(size: 400, pages: 1)
        await world.server.remove(330)
        await world.server.holdNext(.page)

        let refresh = Task { await world.model.refresh() }
        await world.server.awaitHeld(.page)
        world.model.pendingRemovedRefs.insert(MessageRef(folder: "INBOX", uid: 399))
        await world.server.release(.page)
        await refresh.value

        XCTAssertTrue(world.model.envelopes.contains { $0.uid == 330 }, "the read was dropped, not installed")
        world.model.pendingRemovedRefs.remove(MessageRef(folder: "INBOX", uid: 399))
        await world.model.refresh()
        XCTAssertFalse(world.model.envelopes.contains { $0.uid == 330 })
        try await world.assertAligned()
    }

    func testABulkSelectionHoldsTheReadUntilItIsCleared() async throws {
        let world = try await World.opened(size: 400, pages: 1)
        let pagesBefore = await world.server.pageCalls.count
        world.model.bulkMode = true
        world.model.selectedRefs = [MessageRef(folder: "INBOX", uid: 380)]
        await world.server.remove(330)

        await world.model.refresh()
        let pagesDuring = await world.server.pageCalls.count
        XCTAssertEqual(pagesDuring, pagesBefore, "rows don't move under a selection being built")

        world.model.selectedRefs = []
        await world.model.refresh()
        XCTAssertFalse(world.model.envelopes.contains { $0.uid == 330 })
        try await world.assertAligned()
    }

    /// A refresh asked for while a quiet one is out waits for it (#1820),
    /// so the quiet pass's top page lands on the window it was asked for,
    /// never on one a re-read has since moved deep. The rerun then sees the
    /// change and reads the window again, centred on the viewport.
    func testARefreshAskedForWhileOneIsOutRealignsTheWindowOnceThatOneLands() async throws {
        let world = try await World.opened(size: 1000, pages: 2)
        world.model.visibleRowIndices = [380: 1, 420: 1]
        await world.server.holdNext(.top)
        let quiet = Task { await world.model.refresh() }
        await world.server.awaitHeld(.top)

        // Enough arrivals that the rows' reach passes the window cap, so the
        // re-read centres on the viewport, plus a removal to trigger it.
        await world.server.arrive(200)
        await world.server.remove(900)
        let rerun = Task { await world.model.refresh() }
        try await waitUntilOnMainActor { world.model.refreshFlight.waiting == 1 }
        XCTAssertFalse(world.model.hasTrimmedFront, "nothing moves the window while the quiet pass is out")

        await world.server.release(.top)
        await quiet.value
        await rerun.value
        XCTAssertTrue(world.model.hasTrimmedFront)
        try await world.assertAligned()
    }

    func testAFailedReadFromTheTopIsReportedAndADeepOneIsNot() async throws {
        let top = try await World.opened(size: 400, pages: 1)
        await top.server.remove(330)
        await top.server.setPagesFail(true)
        await top.model.refresh()
        XCTAssertNotNil(top.model.errorMessage)

        let deep = try await World.opened(size: 600, jumpTo: 500)
        await deep.server.arrive(1)
        await deep.server.setPagesFail(true)
        await deep.model.refresh()
        XCTAssertNil(deep.model.errorMessage)
    }

    // MARK: - #1818: changes above a trimmed window

    func testNewMailAboveATrimmedWindowRealignsItAndScrollingUpSkipsNothing() async throws {
        let world = try await World.opened(size: 600, jumpTo: 500)
        XCTAssertTrue(world.model.hasTrimmedFront)
        await world.server.arrive(1)

        await world.model.refresh()
        try await world.assertAligned()

        let loaded = world.model.envelopes.count
        world.model.ensureLoaded(around: Int(world.model.windowStart))
        await world.model.loadPrevTask?.value
        XCTAssertGreaterThan(world.model.envelopes.count, loaded, "scrolling up loads the page above")
        try await world.assertAligned()
    }

    func testARemovalAboveATrimmedWindowRealignsIt() async throws {
        let world = try await World.opened(size: 600, jumpTo: 500)
        await world.server.remove(500)

        await world.model.refresh()
        try await world.assertAligned()

        let loaded = world.model.envelopes.count
        world.model.ensureLoaded(around: Int(world.model.windowStart))
        await world.model.loadPrevTask?.value
        XCTAssertGreaterThan(world.model.envelopes.count, loaded)
        try await world.assertAligned()
    }

    func testAQuietRefreshOfATrimmedWindowReadsNothing() async throws {
        let world = try await World.opened(size: 600, jumpTo: 500)
        let pagesBefore = await world.server.pageCalls.count

        await world.model.refresh()

        let pages = await world.server.pageCalls
        let tops = await world.server.topCalls
        XCTAssertEqual(pages.count, pagesBefore)
        XCTAssertEqual(tops.count, 1, "only the open's top page")
    }

    // MARK: - Arrivals the top page doesn't hold

    func testMailMovedInBelowTheTopPageRealignsThePaginatedWindow() async throws {
        let world = try await World.opened(size: 400, pages: 1)
        await world.server.arrive(at: 120)

        await world.model.refresh()

        try await world.assertAligned()
        let arrived = await world.server.uids[120]
        XCTAssertTrue(world.model.envelopes.contains { $0.uid == arrived })
    }

    // MARK: - Opening from the snapshot

    func testAnOfflineOpenShowsTheWholeSnapshot() async throws {
        let world = try await World.opened(size: 400, pages: 1)
        await world.persistSnapshot()
        await world.server.setOffline(true)
        let pagesBefore = await world.server.pageCalls.count

        let reopened = world.makeModel()
        await reopened.loadInitial()

        XCTAssertEqual(reopened.envelopes.count, 250)
        let pages = await world.server.pageCalls
        XCTAssertEqual(pages.count, pagesBefore)
    }

    func testAnOnlineOpenReadsTheSnapshotWindowAgainAndKeepsWhatItDidntCover() async throws {
        let world = try await World.opened(size: 600, pages: 2)
        await world.persistSnapshot()
        // Deleted while the folder was closed.
        await world.server.remove(500)

        let reopened = world.makeModel()
        await reopened.loadInitial()

        let pages = await world.server.pageCalls
        XCTAssertEqual(pages.last, Page(offset: 0, limit: 250))
        XCTAssertFalse(reopened.envelopes.contains { $0.uid == 500 })
        try await world.assertAligned(reopened)
        // Nothing proves where the rows past the read went, so they stay
        // on disk for the next offline open.
        let cached = try await world.snapshotUIDs()
        XCTAssertTrue(cached.contains(200), "a row the read didn't cover is kept")
        XCTAssertEqual(cached.count, 450)
    }

    func testAnOpenThatReadsTheWholeFolderClearsRowsGoneSinceTheLastSession() async throws {
        let world = try await World.opened(size: 120, pages: 1)
        await world.persistSnapshot()
        for uid: UInt32 in [100, 90, 80] { await world.server.remove(uid) }

        let reopened = world.makeModel()
        await reopened.loadInitial()

        let cached = try await world.snapshotUIDs()
        let server = await world.server.uids
        XCTAssertEqual(cached, Set(server))
        try await world.assertAligned(reopened)
    }
}

// MARK: - Harness

private struct Page: Equatable, Sendable {
    let offset: UInt32
    let limit: UInt32
}

/// A folder as the server holds it: UIDs in sort position (newest first),
/// with STATUS and every page computed from that one list.
private actor ServerFolder: ImapClient {
    enum Call: Hashable, Sendable { case page, top }

    private(set) var uids: [UInt32]
    private var dates: [UInt32: Date] = [:]
    private var nextUid: UInt32
    private var offline = false
    private var pagesFail = false
    private(set) var pageCalls: [Page] = []
    private(set) var topCalls: [UInt32] = []
    private var toHold: Set<Call> = []
    private var held: [Call: CheckedContinuation<Void, Never>] = [:]
    private var arrivals: [Call: CheckedContinuation<Void, Never>] = [:]

    init(size: Int) {
        uids = Array((1...UInt32(size)).reversed())
        nextUid = UInt32(size) + 1
        for uid in uids { dates[uid] = Self.date(for: uid) }
    }

    private static func date(for uid: UInt32) -> Date {
        Date(timeIntervalSince1970: 1_700_000_000 + Double(uid) * 60)
    }

    func remove(_ uid: UInt32) { uids.removeAll { $0 == uid } }
    func removeAll() { uids.removeAll() }

    /// New mail on top.
    func arrive(_ count: Int) {
        for _ in 0..<count {
            dates[nextUid] = Self.date(for: nextUid)
            uids.insert(nextUid, at: 0)
            nextUid += 1
        }
    }

    /// A message moved in with an older date, so it sorts below the top.
    func arrive(at position: Int) {
        let newer = dates[uids[position - 1]] ?? Date()
        let older = dates[uids[position]] ?? Date()
        dates[nextUid] = Date(timeIntervalSince1970: (newer.timeIntervalSince1970 + older.timeIntervalSince1970) / 2)
        uids.insert(nextUid, at: position)
        nextUid += 1
    }

    func setOffline(_ value: Bool) { offline = value }
    func setPagesFail(_ value: Bool) { pagesFail = value }

    /// Parks the next call of `call`'s kind until `release(_:)`; the answer
    /// is computed from the folder as it stands at release.
    func holdNext(_ call: Call) { toHold.insert(call) }

    func awaitHeld(_ call: Call) async {
        guard held[call] == nil else { return }
        await withCheckedContinuation { arrivals[call] = $0 }
    }

    func release(_ call: Call) { held.removeValue(forKey: call)?.resume() }

    private func parkIfHeld(_ call: Call) async {
        guard toHold.remove(call) != nil else { return }
        await withCheckedContinuation { continuation in
            held[call] = continuation
            arrivals.removeValue(forKey: call)?.resume()
        }
    }

    private func envelope(_ uid: UInt32) -> Envelope {
        let date = dates[uid]
        return Envelope(uid: uid, date: date, subject: "Message \(uid)", internalDate: date)
    }

    func status(path: String, flagged: Bool) async throws -> FolderStatus {
        if offline { throw CabalmailError.network("offline") }
        return FolderStatus(messages: uids.count, unseen: 0, flagged: 0, uidValidity: 7, uidNext: nextUid)
    }

    func envelopes(folder: String, offset: UInt32, limit: UInt32, sort: SortCriterion) async throws -> [Envelope] {
        await parkIfHeld(.page)
        if offline || pagesFail { throw CabalmailError.network("offline") }
        pageCalls.append(Page(offset: offset, limit: limit))
        let lower = min(Int(offset), uids.count)
        let upper = min(lower + Int(limit), uids.count)
        return uids[lower..<upper].map(envelope)
    }

    func topEnvelopes(
        folder: String, limit: UInt32, totalMessages: UInt32, sort: SortCriterion
    ) async throws -> [Envelope] {
        await parkIfHeld(.top)
        if offline { throw CabalmailError.network("offline") }
        topCalls.append(limit)
        return uids.prefix(Int(limit)).map(envelope)
    }

    func move(folder: String, uids moved: [UInt32], destination: String, markSeen: Bool) async throws {
        uids.removeAll { moved.contains($0) }
    }

    func listFolders() async throws -> [Folder] { throw unexpected() }
    func createFolder(name: String, parent: String?) async throws { throw unexpected() }
    func deleteFolder(path: String) async throws { throw unexpected() }
    func subscribe(path: String) async throws { throw unexpected() }
    func unsubscribe(path: String) async throws { throw unexpected() }
    func fetchBody(folder: String, uid: UInt32) async throws -> RawMessage { throw unexpected() }
    func setFlags(folder: String, uids: [UInt32], flags: Set<Flag>, operation: FlagOperation) async throws {
        throw unexpected()
    }
    func purge(folder: String, uids: [UInt32]) async throws { throw unexpected() }
    func emptyTrash(folder: String) async throws { throw unexpected() }
    func markFolderRead(folder: String) async throws -> Int { throw unexpected() }
    func searchEnvelopes(_ query: SearchQuery) async throws -> SearchResult { throw unexpected() }

    private func unexpected() -> Error { CabalmailError.protocolError("ServerFolder: unexpected call") }
}

/// One client over one `ServerFolder`, so a second model reopens the same
/// envelope snapshot and body cache.
@MainActor
private struct World {
    let server: ServerFolder
    let client: CabalmailClient
    let mailStore: MailSessionStore
    let model: MessageListViewModel

    /// A folder of `size` opened (its 50-row top page), then scrolled down
    /// `pages` load-more pages of 200 rows.
    static func opened(size: Int, pages: Int) async throws -> World {
        let world = try World(size: size)
        await world.model.loadInitial()
        for _ in 0..<pages {
            world.model.ensureLoaded(around: world.model.envelopes.count - 1)
            await world.model.loadMoreTask?.value
        }
        return world
    }

    /// A folder of `size` opened, then jumped deep (End key, scrollbar) so
    /// the window no longer starts at the top.
    static func opened(size: Int, jumpTo index: Int) async throws -> World {
        let world = try World(size: size)
        await world.model.loadInitial()
        world.model.ensureLoaded(around: index)
        await world.model.loadWindowTask?.value
        return world
    }

    private init(size: Int) throws {
        let server = ServerFolder(size: size)
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cabalmail-window-tests-\(UUID().uuidString)")
        let config = TestFixtures.makeConfiguration()
        let auth = NullAuthService()
        let client = CabalmailClient(
            configuration: config,
            authService: auth,
            apiClient: URLSessionApiClient(configuration: config, authService: auth, transport: NullHTTPTransport()),
            imapClient: server,
            addressCache: AddressCache(),
            envelopeCache: try EnvelopeCache(directory: tmp.appendingPathComponent("e")),
            bodyCache: try MessageBodyCache(directory: tmp.appendingPathComponent("b")),
            draftStore: try DraftStore(directory: tmp.appendingPathComponent("d")),
            outbox: try Outbox(directory: tmp.appendingPathComponent("o"))
        )
        let mailStore = AppState().mailStore
        self.server = server
        self.client = client
        self.mailStore = mailStore
        self.model = Self.makeModel(client: client, mailStore: mailStore)
    }

    private static func makeModel(client: CabalmailClient, mailStore: MailSessionStore) -> MessageListViewModel {
        MessageListViewModel(
            folder: Folder(path: "INBOX", attributes: [], isSubscribed: true),
            client: client,
            preferences: Preferences(store: InMemoryPreferenceStore()),
            mailStore: mailStore
        )
    }

    /// A fresh model over the same client: the folder opened again.
    func makeModel() -> MessageListViewModel {
        Self.makeModel(client: client, mailStore: mailStore)
    }

    /// Writes the loaded window to the snapshot now, as the debounced write
    /// after a page would once scrolling settled, and stops that write.
    func persistSnapshot() async {
        await model.stopWatching()
        try? await client.envelopeCache.merge(
            envelopes: model.envelopes,
            uidValidity: 7,
            uidNext: (model.envelopes.map(\.uid).max() ?? 0) + 1,
            into: "INBOX"
        )
    }

    func snapshotUIDs() async throws -> Set<UInt32> {
        let snapshot = await client.envelopeCache.snapshot(for: "INBOX")
        return Set(try XCTUnwrap(snapshot).envelopes.keys)
    }

    /// Every loaded index holds the UID the server has at that position.
    func assertAligned(
        _ list: MessageListViewModel? = nil, file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let list = list ?? model
        let serverUids = await server.uids
        XCTAssertFalse(list.envelopes.isEmpty, "nothing loaded", file: file, line: line)
        let start = Int(list.windowStart)
        let end = start + list.envelopes.count
        XCTAssertLessThanOrEqual(end, serverUids.count, "window runs past the folder", file: file, line: line)
        let loaded = Set(list.envelopes.map(\.uid))
        let expected = Set(serverUids[min(start, serverUids.count)..<min(end, serverUids.count)])
        XCTAssertEqual(loaded, expected, "window [\(start), \(end)) is off the server's positions",
                       file: file, line: line)
    }
}

import XCTest
import CabalmailKit
@testable import CabalmailUI

/// The world the message list's window-alignment suites share
/// (`MessageListWindowReconcileTests`, `MessageListSavedWindowTests`): a
/// folder as the server holds it, one client over it, and the assertion
/// those suites both end on -- every loaded index holds the UID the server
/// has at that position.

struct Page: Equatable, Sendable {
    let offset: UInt32
    let limit: UInt32
}

/// A folder as the server holds it: UIDs in sort position (newest first),
/// with STATUS and every page computed from that one list.
actor ServerFolder: ImapClient {
    enum Call: Hashable, Sendable { case page, top }

    private(set) var uids: [UInt32]
    private var dates: [UInt32: Date] = [:]
    private var nextUid: UInt32
    private var offline = false
    /// Messages flagged `\Deleted` elsewhere and not yet expunged: out of
    /// the sort the pages serve, still counted by STATUS MESSAGES.
    private var deletedNotExpunged = 0
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

    /// `\Deleted` set on `uid` by another client, with no expunge: the row
    /// leaves the `NOT DELETED` sort, MESSAGES does not move, UIDNEXT does
    /// not move (#1836).
    func flagDeleted(_ uid: UInt32) {
        guard uids.contains(uid) else { return }
        uids.removeAll { $0 == uid }
        deletedNotExpunged += 1
    }
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
        // The not-deleted count rides the same opt-in the Lambda puts it
        // behind, so only a caller that asked for it gets one.
        return FolderStatus(
            messages: uids.count + deletedNotExpunged, unseen: 0, flagged: 0,
            undeleted: flagged ? uids.count : nil, uidValidity: 7, uidNext: nextUid
        )
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

    /// What the server would answer for these rows, whatever positions they
    /// sit at now.
    func rows(_ wanted: [UInt32]) -> [Envelope] { wanted.map(envelope) }

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
struct World {
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
            world.model.window!.ensureLoaded(around: world.model.envelopes.count - 1)
            await world.model.window!.loadMoreTask?.value
        }
        return world
    }

    /// A folder of `size` opened, then jumped deep (End key, scrollbar) so
    /// the window no longer starts at the top.
    static func opened(size: Int, jumpTo index: Int) async throws -> World {
        let world = try World(size: size)
        await world.model.loadInitial()
        world.model.window!.ensureLoaded(around: index)
        await world.model.window!.loadWindowTask?.value
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

    /// Writes the loaded window to the snapshot now with no record of where
    /// its rows sat -- a snapshot as every build before #1836 left it -- and
    /// stops the debounced write.
    func persistSnapshot() async {
        await model.stopWatching()
        try? await client.envelopeCache.merge(
            envelopes: model.envelopes,
            uidValidity: 7,
            uidNext: (model.envelopes.map(\.uid).max() ?? 0) + 1,
            into: "INBOX"
        )
    }

    /// Runs the real debounced write now, so the snapshot carries the window
    /// record beside the rows (`WindowSnapshot.persistLoadedPages`), and
    /// stops the one the window has pending.
    func persistWindow() async {
        await model.stopWatching()
        await model.window!.snapshot.persistLoadedPages()
    }

    /// Merges rows the loaded window doesn't hold into the snapshot, as the
    /// deeper pages of an earlier session (or the Spotlight sweep's own
    /// merge) leave there: the snapshot accumulates every row ever cached
    /// for the folder while the window moves independently, so it is
    /// routinely wider than the window that proved part of it (#1836).
    func cacheRowsOutsideTheWindow(uids: [UInt32]) async throws {
        let existing = await client.envelopeCache.snapshot(for: "INBOX")
        try await client.envelopeCache.merge(
            envelopes: await server.rows(uids),
            uidValidity: 7,
            uidNext: existing?.uidNext ?? 1,
            window: existing?.window,
            into: "INBOX"
        )
    }

    /// Rewrites the saved record, as a session that wrote one over other
    /// rows, or in another order, would have left it.
    func rewriteWindowRecord(
        _ transform: (EnvelopeCache.WindowRecord) -> EnvelopeCache.WindowRecord
    ) async throws {
        let stored = await client.envelopeCache.snapshot(for: "INBOX")
        let snapshot = try XCTUnwrap(stored)
        let record = try XCTUnwrap(snapshot.window)
        try await client.envelopeCache.store(
            EnvelopeCache.Snapshot(
                uidValidity: snapshot.uidValidity,
                uidNext: snapshot.uidNext,
                envelopes: snapshot.envelopes,
                window: transform(record)
            ),
            for: "INBOX"
        )
    }

    func savedWindowRecord() async -> EnvelopeCache.WindowRecord? {
        await client.envelopeCache.snapshot(for: "INBOX")?.window
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
        let start = Int(list.window!.windowStart)
        let end = start + list.envelopes.count
        XCTAssertLessThanOrEqual(end, serverUids.count, "window runs past the folder", file: file, line: line)
        let loaded = Set(list.envelopes.map(\.uid))
        let expected = Set(serverUids[min(start, serverUids.count)..<min(end, serverUids.count)])
        XCTAssertEqual(loaded, expected, "window [\(start), \(end)) is off the server's positions",
                       file: file, line: line)
    }
}

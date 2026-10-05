import Foundation
import CabalmailKit

/// Scripted `ImapClient` double. Each member records its call and answers
/// from a script; an unscripted member traps by throwing
/// `protocolError("FakeImapClient: unexpected call")`. A trap fails a test
/// only where the caller surfaces the error: the list's paging paths swallow
/// theirs, so paging tests assert on the recorded calls instead.
public actor FakeImapClient: ImapClient {
    public struct FlagCall: Sendable {
        public let folder: String
        public let uids: Set<UInt32>
        public let flags: Set<Flag>
        public let operation: FlagOperation
    }

    public struct MoveCall: Sendable {
        public let folder: String
        public let uids: Set<UInt32>
        public let destination: String
        public let markSeen: Bool
    }

    public struct PurgeCall: Sendable {
        public let folder: String
        public let uids: Set<UInt32>
    }

    public private(set) var flagCalls: [FlagCall] = []
    public private(set) var moveCalls: [MoveCall] = []
    public private(set) var purgeCalls: [PurgeCall] = []
    /// Folders handed to `markFolderRead(folder:)`, in order.
    public private(set) var markFolderReadCalls: [String] = []
    // FIFO scripts; an empty queue means "succeed". Seeded via the
    // scriptFlagResults / scriptMoveResults helpers below.
    private var flagResults: [Result<Void, Error>] = []
    private var moveResults: [Result<Void, Error>] = []
    private var purgeResults: [Result<Void, Error>] = []
    /// Scripted `flipped` counts (or failures) for `markFolderRead`; an
    /// empty queue reports zero flipped.
    private var markFolderReadResults: [Result<Int, Error>] = []

    public init() {}

    public func scriptMarkFolderReadResults(_ results: [Result<Int, Error>]) {
        markFolderReadResults = results
    }

    public func scriptFlagResults(_ results: [Result<Void, Error>]) {
        flagResults = results
    }

    public func scriptMoveResults(_ results: [Result<Void, Error>]) {
        moveResults = results
    }

    public func scriptPurgeResults(_ results: [Result<Void, Error>]) {
        purgeResults = results
    }

    // Initial-load script (status + top page), used by the loadInitial
    // tests. Unscripted, both members keep trapping.
    private var statusResult: FolderStatus?
    private var topEnvelopesResult: [Envelope]?

    public func scriptInitialLoad(status: FolderStatus, topEnvelopes: [Envelope]) {
        statusResult = status
        topEnvelopesResult = topEnvelopes
    }

    // Read-path, refresh and paging scripts. Each queue is consumed first;
    // once empty, `status` falls back to `scriptInitialLoad`'s value and
    // `envelopes` to the scripted folder contents, then both trap.
    private var statusResults = ResultQueue<FolderStatus>()
    private var envelopesResults = ResultQueue<[Envelope]>()
    private var folderContents: ScriptedFolderContents?
    private var bodies: [BodyKey: ResultQueue<Data>] = [:]
    private var emptyTrashResults = ResultQueue<Void>()
    private var idleStreams = ScriptedIdleStreams()

    public private(set) var statusCalls: [StatusCall] = []
    public private(set) var topEnvelopesCalls: [TopEnvelopesCall] = []
    public private(set) var envelopesCalls: [EnvelopesCall] = []
    public private(set) var fetchBodyCalls: [FetchBodyCall] = []
    /// Folders handed to `emptyTrash(folder:)`, in order.
    public private(set) var emptyTrashCalls: [String] = []
    /// Folders handed to `idle(folder:)`, in order, scripted or not.
    public private(set) var idleFolders: [String] = []
    /// Scripted idle streams whose consumer stopped listening.
    public private(set) var idleTerminations = 0

    /// STATUS answers (or failures) for the next calls, ahead of the
    /// `scriptInitialLoad` value.
    public func scriptStatusResults(_ results: [Result<FolderStatus, Error>]) {
        statusResults.append(results)
    }

    /// Pages (or failures) for the next `envelopes(offset:)` calls.
    public func scriptEnvelopesResults(_ results: [Result<[Envelope], Error>]) {
        envelopesResults.append(results)
    }

    /// The whole folder in server order; `envelopes(offset:limit:)` slices it.
    public func scriptFolderContents(_ envelopes: [Envelope]) {
        folderContents = ScriptedFolderContents(envelopes: envelopes)
    }

    /// Raw message bytes (or failures) for the next opens of one message.
    public func scriptBody(folder: String, uid: UInt32, _ results: [Result<Data, Error>]) {
        bodies[BodyKey(folder: folder, uid: uid), default: ResultQueue()].append(results)
    }

    /// Results for the next `emptyTrash` calls; unscripted, it traps.
    public func scriptEmptyTrashResults(_ results: [Result<Void, Error>]) {
        emptyTrashResults.append(results)
    }

    /// From now on `idle(folder:)` hands back a stream the test feeds with
    /// `emitIdle` and ends with `finishIdle`.
    public func scriptIdle() {
        idleStreams.script()
    }

    public func emitIdle(_ kind: IdleEvent.Kind, folder: String = "INBOX") {
        idleStreams.emit(kind, folder: folder)
    }

    public func finishIdle(folder: String = "INBOX", throwing error: Error? = nil) {
        idleStreams.finish(folder: folder, throwing: error)
    }

    /// Waits until `idle(folder:)` has been called `count` times in all.
    public func awaitIdleOpened(count: Int = 1) async {
        guard idleFolders.count < count else { return }
        await withCheckedContinuation { idleOpenWaiters.append((count, $0)) }
    }

    private var idleOpenWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    private func noteIdleTerminated() {
        idleTerminations += 1
    }

    // Structured-search script. `scriptSearch` scripts one result returned
    // on every call (fine while `nextCursor` is nil — the chunked walk and
    // the scroll-driven load-more both stop there). Paging tests script a
    // queue with `scriptSearchPages`, consumed one page per call; when the
    // queue drains, calls fall back to the single result, then trap.
    private var searchResult: SearchResult?
    private var searchPages: [SearchResult] = []

    // Every search request, in order — lets tests assert the limit/cursor
    // each fetch carried.
    public private(set) var searchCalls: [SearchQuery] = []

    public func scriptSearch(_ result: SearchResult) {
        searchResult = result
    }

    public func scriptSearchPages(_ pages: [SearchResult]) {
        searchPages = pages
    }

    // A search the test can hold open at the transport, so a result can be
    // made to land after the user has ended the search (#1536):
    // `holdNextSearch()` parks the next request, `awaitHeldSearch()` waits
    // for it to arrive, `releaseHeldSearch()` lets it answer.
    private var holdNext = false
    private var heldSearch: CheckedContinuation<Void, Never>?
    private var searchArrived: CheckedContinuation<Void, Never>?

    public func holdNextSearch() {
        holdNext = true
    }

    public func awaitHeldSearch() async {
        guard heldSearch == nil else { return }
        await withCheckedContinuation { searchArrived = $0 }
    }

    public func releaseHeldSearch() {
        holdNext = false
        heldSearch?.resume()
        heldSearch = nil
    }

    // The same hold for the list's own wire calls, so a test can make a
    // move, STATUS or top-page fetch answer after something else has
    // happened -- e.g. a refresh fetched before a dispose's move landed that
    // only arrives once the dispose has finished. `holdNext(_:)` parks the
    // next such call, `awaitHeld(_:)` waits for it to arrive, and
    // `releaseHeld(_:)` lets it answer with whatever is scripted by then.
    public enum HeldCall: Hashable, Sendable { case move, status, topEnvelopes, envelopes, fetchBody, setFlags, purge }
    private var callsToHold: Set<HeldCall> = []
    private var heldCalls: [HeldCall: CheckedContinuation<Void, Never>] = [:]
    private var heldCallArrivals: [HeldCall: CheckedContinuation<Void, Never>] = [:]

    public func holdNext(_ call: HeldCall) {
        callsToHold.insert(call)
    }

    public func awaitHeld(_ call: HeldCall) async {
        guard heldCalls[call] == nil else { return }
        await withCheckedContinuation { heldCallArrivals[call] = $0 }
    }

    public func releaseHeld(_ call: HeldCall) {
        heldCalls.removeValue(forKey: call)?.resume()
    }

    private func parkIfHeld(_ call: HeldCall) async {
        guard callsToHold.remove(call) != nil else { return }
        await withCheckedContinuation { continuation in
            heldCalls[call] = continuation
            heldCallArrivals.removeValue(forKey: call)?.resume()
        }
    }

    public func searchEnvelopes(_ query: SearchQuery) async throws -> SearchResult {
        searchCalls.append(query)
        if holdNext {
            holdNext = false
            await withCheckedContinuation { continuation in
                heldSearch = continuation
                searchArrived?.resume()
                searchArrived = nil
            }
        }
        if !searchPages.isEmpty { return searchPages.removeFirst() }
        guard let searchResult else { return try trap() }
        return searchResult
    }

    public func setFlags(
        folder: String,
        uids: [UInt32],
        flags: Set<Flag>,
        operation: FlagOperation
    ) async throws {
        flagCalls.append(FlagCall(
            folder: folder, uids: Set(uids), flags: flags, operation: operation
        ))
        await parkIfHeld(.setFlags)
        if !flagResults.isEmpty {
            try flagResults.removeFirst().get()
        }
    }

    public func move(folder: String, uids: [UInt32], destination: String, markSeen: Bool) async throws {
        moveCalls.append(MoveCall(
            folder: folder, uids: Set(uids), destination: destination, markSeen: markSeen
        ))
        await parkIfHeld(.move)
        if !moveResults.isEmpty {
            try moveResults.removeFirst().get()
        }
    }

    public func purge(folder: String, uids: [UInt32]) async throws {
        purgeCalls.append(PurgeCall(folder: folder, uids: Set(uids)))
        await parkIfHeld(.purge)
        if !purgeResults.isEmpty {
            try purgeResults.removeFirst().get()
        }
    }

    public func markFolderRead(folder: String) async throws -> Int {
        markFolderReadCalls.append(folder)
        if !markFolderReadResults.isEmpty {
            return try markFolderReadResults.removeFirst().get()
        }
        return 0
    }

    // Everything below is off the bulk paths: trap.
    public func listFolders() async throws -> [Folder] { try trap() }
    public func createFolder(name: String, parent: String?) async throws { try trapVoid() }
    public func deleteFolder(path: String) async throws { try trapVoid() }
    public func subscribe(path: String) async throws { try trapVoid() }
    public func unsubscribe(path: String) async throws { try trapVoid() }
    public func status(path: String, flagged: Bool) async throws -> FolderStatus {
        statusCalls.append(StatusCall(path: path, flagged: flagged))
        await parkIfHeld(.status)
        // Mirror the production transport: a URLSession data task whose
        // surrounding Task is cancelled fails with `URLError.cancelled`,
        // which `URLSessionHTTPTransport` normalizes to `network(...)`.
        if Task.isCancelled { throw CabalmailError.network("cancelled") }
        if let scripted = statusResults.next() { return try scripted.get() }
        guard let statusResult else { return try trap() }
        return statusResult
    }
    public func envelopes(
        folder: String, offset: UInt32, limit: UInt32, sort: SortCriterion
    ) async throws -> [Envelope] {
        envelopesCalls.append(EnvelopesCall(folder: folder, offset: offset, limit: limit, sort: sort))
        await parkIfHeld(.envelopes)
        if Task.isCancelled { throw CabalmailError.network("cancelled") }
        if let scripted = envelopesResults.next() { return try scripted.get() }
        guard let folderContents else { return try trap() }
        return folderContents.page(offset: offset, limit: limit)
    }
    public func topEnvelopes(
        folder: String, limit: UInt32, totalMessages: UInt32, sort: SortCriterion
    ) async throws -> [Envelope] {
        topEnvelopesCalls.append(TopEnvelopesCall(
            folder: folder, limit: limit, totalMessages: totalMessages, sort: sort
        ))
        await parkIfHeld(.topEnvelopes)
        // Cancellation-sensitive for the same reason as `status(path:flagged:)`.
        if Task.isCancelled { throw CabalmailError.network("cancelled") }
        guard let topEnvelopesResult else { return try trap() }
        return topEnvelopesResult
    }
    public func fetchBody(folder: String, uid: UInt32) async throws -> RawMessage {
        fetchBodyCalls.append(FetchBodyCall(folder: folder, uid: uid))
        await parkIfHeld(.fetchBody)
        if Task.isCancelled { throw CabalmailError.network("cancelled") }
        guard let scripted = bodies[BodyKey(folder: folder, uid: uid)]?.next() else { return try trap() }
        // Like `ApiBackedImapClient`, the raw fetch carries no flags.
        return RawMessage(uid: uid, bytes: try scripted.get())
    }
    public func emptyTrash(folder: String) async throws {
        emptyTrashCalls.append(folder)
        guard let scripted = emptyTrashResults.next() else { return try trapVoid() }
        try scripted.get()
    }
    public func idle(folder: String) async throws -> AsyncThrowingStream<IdleEvent, Error> {
        idleFolders.append(folder)
        let ready = idleOpenWaiters.filter { $0.count <= idleFolders.count }
        idleOpenWaiters.removeAll { $0.count <= idleFolders.count }
        ready.forEach { $0.continuation.resume() }
        return idleStreams.open(folder: folder) { [weak self] in
            Task { await self?.noteIdleTerminated() }
        }
    }

    private func trap<T>() throws -> T {
        throw CabalmailError.protocolError("FakeImapClient: unexpected call")
    }

    private func trapVoid() throws {
        throw CabalmailError.protocolError("FakeImapClient: unexpected call")
    }
}

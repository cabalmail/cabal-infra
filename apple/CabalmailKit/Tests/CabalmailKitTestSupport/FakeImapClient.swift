import Foundation
import CabalmailKit

/// Scripted `ImapClient` double. Only the members the bulk paths use are
/// functional — `setFlags` / `move` record their calls and pop a scripted
/// result — and everything else traps loudly, so a test that wanders onto
/// an unexpected wire path fails instead of silently no-oping.
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
    public enum HeldCall: Hashable, Sendable { case move, status, topEnvelopes }
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
        await parkIfHeld(.status)
        // Mirror the production transport: a URLSession data task whose
        // surrounding Task is cancelled fails with `URLError.cancelled`,
        // which `URLSessionHTTPTransport` normalizes to `network(...)`.
        if Task.isCancelled { throw CabalmailError.network("cancelled") }
        guard let statusResult else { return try trap() }
        return statusResult
    }
    public func envelopes(
        folder: String, offset: UInt32, limit: UInt32, sort: SortCriterion
    ) async throws -> [Envelope] { try trap() }
    public func topEnvelopes(
        folder: String, limit: UInt32, totalMessages: UInt32, sort: SortCriterion
    ) async throws -> [Envelope] {
        await parkIfHeld(.topEnvelopes)
        // Cancellation-sensitive for the same reason as `status(path:flagged:)`.
        if Task.isCancelled { throw CabalmailError.network("cancelled") }
        guard let topEnvelopesResult else { return try trap() }
        return topEnvelopesResult
    }
    public func fetchBody(folder: String, uid: UInt32) async throws -> RawMessage { try trap() }

    private func trap<T>() throws -> T {
        throw CabalmailError.protocolError("FakeImapClient: unexpected call")
    }

    private func trapVoid() throws {
        throw CabalmailError.protocolError("FakeImapClient: unexpected call")
    }
}

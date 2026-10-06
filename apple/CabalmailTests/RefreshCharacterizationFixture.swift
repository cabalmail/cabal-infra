import XCTest
import CabalmailKit
@testable import CabalmailUI

/// Shared set-up for the workstream 0.8 refresh characterization suites
/// (`MessageListRefreshCharacterizationTests` and
/// `MessageListReconcileCharacterizationTests`): list models for one folder
/// over one `FakeImapClient`, with a fresh `AppState` and in-memory
/// preferences per test. It is the one place those suites read or poke the
/// list's window internals, so a rename in the 0.8 refactor is fixed here.
///
/// The folder is deliberately not INBOX: nothing pinned depends on it, and an
/// INBOX count would also drive the app-icon badge from the test host. Each
/// client's caches live in their own temp directory, removed by
/// `removeScratch()`.
@MainActor
final class RefreshCharacterizationFixture {
    let folderPath = "Work"
    let imap = FakeImapClient()
    let appState = AppState()
    /// The models' shared mail state: the counts they publish and the shields
    /// they read.
    var mailStore: MailSessionStore { appState.mailStore }
    private var scratchRoots: [URL] = []

    func removeScratch() {
        for root in scratchRoots { try? FileManager.default.removeItem(at: root) }
        scratchRoots = []
    }

    /// The identity of `uid` in the fixture's folder.
    func ref(_ uid: UInt32) -> MessageRef {
        MessageRef(folder: folderPath, uid: uid)
    }

    /// A list with `loaded` in memory and nothing learned from the server
    /// yet: no UIDVALIDITY, no snapshot, counts at zero but `total`.
    func makeModel(
        loaded: [UInt32] = [],
        flags: Set<Flag> = [],
        total: UInt32 = 0
    ) async throws -> MessageListViewModel {
        let model = try TestFixtures.makeModel(
            imap: imap, envelopes: rows(loaded, flags: flags), folderPath: folderPath, mailStore: mailStore
        )
        model.totalMessages = total
        await track(model.client)
        return model
    }

    /// The same folder opened again in the same session: a new list model
    /// over `model`'s client, preferences and mail store.
    func reopen(_ model: MessageListViewModel) -> MessageListViewModel {
        MessageListViewModel(
            folder: model.folder, client: model.client, preferences: model.preferences, mailStore: mailStore
        )
    }

    func makeSearchScopeModel() async throws -> MessageListViewModel {
        let client = try TestFixtures.makeClient(imap: imap)
        await track(client)
        return MessageListViewModel(
            scope: .search,
            client: client,
            preferences: Preferences(store: InMemoryPreferenceStore()),
            mailStore: mailStore
        )
    }

    /// Records the per-client root `TestFixtures.makeClient` made for the
    /// caches. Only a directory named the way that factory names its roots
    /// is ever deleted, so a change to its layout leaks a temp directory
    /// rather than deleting someone else's.
    private func track(_ client: CabalmailClient) async {
        let root = await client.bodyCache.directory.deletingLastPathComponent()
        guard root.lastPathComponent.hasPrefix("cabalmail-tests-") else { return }
        scratchRoots.append(root)
    }

    // MARK: Server answers

    func rows(_ uids: [UInt32], flags: Set<Flag> = []) -> [Envelope] {
        uids.map { TestFixtures.makeEnvelope(uid: $0, flags: flags) }
    }

    /// `high` down to `low`: a folder in the server's newest-first order,
    /// which is also the client's order for undated envelopes.
    func newestFirst(_ high: UInt32, through low: UInt32) -> [UInt32] {
        Array(stride(from: high, through: low, by: -1))
    }

    func status(
        messages: Int?,
        unseen: Int = 0,
        flagged: Int = 0,
        uidValidity: UInt32? = 7,
        uidNext: UInt32 = 1_001
    ) -> FolderStatus {
        FolderStatus(
            messages: messages, unseen: unseen, flagged: flagged, uidValidity: uidValidity, uidNext: uidNext
        )
    }

    /// Every STATUS answers this, and every top page is `page`. A held call
    /// answers with whatever is scripted when it is released.
    func scriptRefresh(
        messages: Int?,
        page: [UInt32],
        unseen: Int = 0,
        flagged: Int = 0,
        uidValidity: UInt32? = 7,
        uidNext: UInt32? = nil
    ) async {
        let next = uidNext ?? (page.max() ?? 0) + 1
        await imap.scriptInitialLoad(
            status: status(
                messages: messages, unseen: unseen, flagged: flagged, uidValidity: uidValidity, uidNext: next
            ),
            topEnvelopes: rows(page)
        )
    }

    func searchResult(_ envelopes: [Envelope], cursor: String? = nil) -> SearchResult {
        SearchResult(
            envelopes: envelopes.map { SearchedEnvelope(envelope: $0, folder: folderPath) },
            totalEstimate: envelopes.count,
            nextCursor: cursor,
            foldersSearched: [folderPath],
            truncated: false
        )
    }

    // MARK: Recorded wire calls, as comparable strings

    func statusCalls() async -> [String] {
        let calls = await imap.statusCalls
        return calls.map { "\($0.path) flagged=\($0.flagged)" }
    }

    func topPageCalls() async -> [String] {
        let calls = await imap.topEnvelopesCalls
        return calls.map { "\($0.folder) limit=\($0.limit) total=\($0.totalMessages) \(describe($0.sort))" }
    }

    func pageCalls() async -> [String] {
        let calls = await imap.envelopesCalls
        return calls.map { "\($0.folder) offset=\($0.offset) limit=\($0.limit) \(describe($0.sort))" }
    }

    private func describe(_ sort: SortCriterion) -> String {
        "\(sort.field.rawValue)/\(sort.direction.rawValue)"
    }

    // MARK: Caches

    func seedSnapshot(
        _ model: MessageListViewModel,
        uids: [UInt32],
        uidValidity: UInt32 = 7
    ) async throws {
        let envelopes = rows(uids)
        try await model.client.envelopeCache.store(
            EnvelopeCache.Snapshot(
                uidValidity: uidValidity,
                uidNext: (uids.max() ?? 0) + 1,
                envelopes: Dictionary(uniqueKeysWithValues: envelopes.map { ($0.uid, $0) })
            ),
            for: folderPath
        )
    }

    func snapshot(_ model: MessageListViewModel) async -> EnvelopeCache.Snapshot? {
        await model.client.envelopeCache.snapshot(for: folderPath)
    }

    func snapshotUIDs(_ model: MessageListViewModel) async -> Set<UInt32>? {
        await snapshot(model).map { Set($0.envelopes.keys) }
    }

    func storeBody(_ model: MessageListViewModel, uid: UInt32, uidValidity: UInt32 = 7) async throws {
        try await model.client.bodyCache.store(
            folder: folderPath, uidValidity: uidValidity, uid: uid, bytes: Data("body \(uid)".utf8)
        )
    }

    func cachedBody(_ model: MessageListViewModel, uid: UInt32, uidValidity: UInt32 = 7) async -> Data? {
        await model.client.bodyCache.fetch(folder: folderPath, uidValidity: uidValidity, uid: uid)
    }

    // MARK: Window internals

    /// Puts the window where `performLoadMore`'s front trim leaves it.
    func trimFront(_ model: MessageListViewModel, to start: UInt32) {
        model.windowStart = start
        model.hasTrimmedFront = true
    }

    func windowStart(_ model: MessageListViewModel) -> UInt32 {
        model.windowStart
    }

    func stagedBottomStart(_ model: MessageListViewModel) -> UInt32? {
        model.bottomPrefetch?.start
    }

    func awaitBottomPrefetch(_ model: MessageListViewModel) async {
        await model.bottomPrefetchTask?.value
    }

    func awaitLoadMore(_ model: MessageListViewModel) async {
        await model.loadMoreTask?.value
    }

    func awaitLoadWindow(_ model: MessageListViewModel) async {
        await model.loadWindowTask?.value
    }
}

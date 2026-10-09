import XCTest
import CabalmailKit
@testable import CabalmailUI

/// One paging test's world for the workstream 0.8 characterization suites of
/// the folder list's sliding-window paging (MessageListPagingCharacterizationTests,
/// MessageListBottomPrefetchCharacterizationTests and
/// MessageListPagingGateCharacterizationTests): a scripted server folder, a
/// scratch cache directory removed at teardown, and the list models built
/// over them.
///
/// The folder is in server order, newest first, and `makeEnvelope` sets no
/// date, so the list's own order (UID descending) agrees with it: index `i`
/// of an `n`-message folder holds UID `n - i`. It is not INBOX, so a refresh
/// publishing its counts never reaches the inbox badge of the host app.
@MainActor
final class ListPagingWorld {
    static let folderPath = "Work"

    /// One recorded `envelopes(offset:limit:)` request.
    struct Page: Equatable, CustomStringConvertible {
        let offset: UInt32
        let limit: UInt32
        var sort: SortCriterion = .default
        var folder: String = ListPagingWorld.folderPath

        var description: String {
            "\(folder)[\(offset)+\(limit) \(sort.field.rawValue) \(sort.direction.rawValue)]"
        }
    }

    let imap = FakeImapClient()
    private let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("list-paging-\(UUID().uuidString)")
    private var models: [MessageListViewModel] = []

    static func serverFolder(size: Int) -> [Envelope] {
        (0..<size).map { TestFixtures.makeEnvelope(uid: UInt32(size - $0)) }
    }

    /// The UIDs an `size`-message folder holds at the absolute indices `range`.
    static func uids(_ range: Range<Int>, size: Int = 1000) -> [UInt32] {
        range.map { UInt32(size - $0) }
    }

    static func status(messages: Int) -> FolderStatus {
        FolderStatus(messages: messages, unseen: 0, flagged: 0, uidValidity: 7, uidNext: UInt32(messages + 1))
    }

    /// Scripts a `size`-message folder: every positional page slices it, and
    /// STATUS and the top page answer from it. `statusCount` makes STATUS
    /// report a different total than the folder pages.
    func scriptServer(size: Int, statusCount: Int? = nil) async {
        let folder = Self.serverFolder(size: size)
        await imap.scriptFolderContents(folder)
        await imap.scriptInitialLoad(
            status: Self.status(messages: statusCount ?? size),
            topEnvelopes: Array(folder.prefix(50))
        )
    }

    /// A list model over the fixture folder with its own caches under the
    /// scratch root, and `preloaded` rows already showing. Nothing runs until
    /// the test drives it.
    func makeModel(preloaded: [Envelope] = []) throws -> MessageListViewModel {
        let directory = root.appendingPathComponent(UUID().uuidString)
        let config = TestFixtures.makeConfiguration()
        let auth = NullAuthService()
        let client = CabalmailClient(
            configuration: config,
            authService: auth,
            apiClient: URLSessionApiClient(configuration: config, authService: auth, transport: NullHTTPTransport()),
            imapClient: imap,
            addressCache: AddressCache(),
            envelopeCache: try EnvelopeCache(directory: directory.appendingPathComponent("envelopes")),
            bodyCache: try MessageBodyCache(directory: directory.appendingPathComponent("bodies")),
            draftStore: try DraftStore(directory: directory.appendingPathComponent("drafts")),
            outbox: try Outbox(directory: directory.appendingPathComponent("outbox"))
        )
        let model = MessageListViewModel(
            folder: Folder(path: Self.folderPath, isSubscribed: true),
            client: client,
            preferences: Preferences(store: InMemoryPreferenceStore()),
            mailStore: AppState().mailStore
        )
        model.envelopes = preloaded
        models.append(model)
        return model
    }

    /// A list as a background refresh leaves it: the first `preloaded` rows of
    /// the folder showing (none for a fresh list), then one `refresh()` for
    /// STATUS and the top page. No bottom page is staged: only `loadInitial`
    /// and `setSort` stage one.
    func openedList(
        size: Int = 1000,
        preloaded: Int = 0,
        statusCount: Int? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> MessageListViewModel {
        await scriptServer(size: size, statusCount: statusCount)
        let model = try makeModel(preloaded: Array(Self.serverFolder(size: size).prefix(preloaded)))
        if preloaded > 0 {
            // Rows a real load left showing line up with the STATUS it read,
            // so the window carries that anchor; a bare window would be read
            // again by position, as one hydrated from the snapshot is.
            let total = UInt32(statusCount ?? size)
            model.window!.alignment.anchor = WindowAnchor(total: total, uidNext: total + 1)
        }
        await model.refresh()
        XCTAssertNil(model.errorMessage, "the opening refresh failed", file: file, line: line)
        return model
    }

    /// Waits for every load the model owns (load-more, load-previous, the far
    /// jump and the bottom prefetch), then checks that none is still running,
    /// so a load moved onto some other task fails here instead of letting a
    /// "nothing changed" assertion pass before the load has run. Call it only
    /// while nothing is held at the fake.
    func settle(
        _ model: MessageListViewModel,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        await model.window!.loadMoreTask?.value
        await model.window!.loadPrevTask?.value
        await model.window!.loadWindowTask?.value
        await model.window!.bottomPrefetchTask?.value
        XCTAssertFalse(model.window!.isLoadingMore, "a load-more is still running", file: file, line: line)
        XCTAssertFalse(model.window!.isLoadingPrevious, "a load-previous is still running", file: file, line: line)
        XCTAssertFalse(model.window!.isLoadingWindow, "a jump is still running", file: file, line: line)
    }

    /// The UIDs the folder's envelope snapshot holds for `model`'s client.
    func snapshotUIDs(_ model: MessageListViewModel) async -> Set<UInt32> {
        guard let snapshot = await model.client.envelopeCache.snapshot(for: Self.folderPath) else {
            return []
        }
        return Set(snapshot.envelopes.keys)
    }

    /// A list whose 250 rows the counts can't place any more (a message was
    /// removed elsewhere, and UIDNEXT can't say where), with a page below
    /// still out: the refresh plans a re-read, which first waits for that
    /// page. Returns the list and the refresh, parked in that wait.
    func refreshWaitingOnAPage() async throws -> (MessageListViewModel, Task<Void, Never>) {
        let model = try await openedList()
        model.window!.ensureLoaded(around: 0)
        await settle(model)
        await model.window!.persistTask?.value
        await imap.answerEnvelopesAfterCancellation()
        await imap.holdNext(.envelopes)
        model.window!.ensureLoaded(around: 100)
        XCTAssertTrue(model.window!.isLoadingMore)
        await imap.awaitHeld(.envelopes)
        await scriptServer(size: 999)
        let refresh = Task { await model.refresh() }
        // Everything from the counts to the wait runs without a suspension.
        try await waitUntilOnMainActor { model.window!.totalMessages == 999 }
        return (model, refresh)
    }

    /// Every page request so far, in order.
    func pages() async -> [Page] {
        await imap.envelopesCalls.map {
            Page(offset: $0.offset, limit: $0.limit, sort: $0.sort, folder: $0.folder)
        }
    }

    /// Cancels every model's own tasks (the debounced snapshot write among
    /// them), then removes the caches.
    func tearDown() async {
        for model in models {
            await model.stopWatching()
        }
        models = []
        try? FileManager.default.removeItem(at: root)
    }
}

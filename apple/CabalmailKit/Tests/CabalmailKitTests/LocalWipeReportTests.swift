import XCTest
import CabalmailKitTestSupport
@testable import CabalmailKit

/// A step of the sign-out wipe that fails says so (account-isolation.md,
/// PR C2). Every step used to be a `try?`, and the two mail caches swallowed
/// a failed removal before it could even be thrown, so a wipe that left the
/// last account's mail on disk looked exactly like one that worked.
final class LocalWipeReportTests: XCTestCase {
    private var root: URL!
    /// Carried in the injected error, so a test finds its own lines in the
    /// process-wide Debug Log.
    private var token: String!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-wipe-report-\(UUID().uuidString)")
        token = UUID().uuidString
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - The wipe

    func testAWipeWhoseOutboxCannotBeRemovedSaysSoAndClearsTheRest() async throws {
        let outbox = try Outbox(
            directory: root.appendingPathComponent("outbox"), fileManager: RefusingFileManager(token: token)
        )
        let client = try makeClient(outbox: outbox)
        try await seedMail(in: client)
        let sender = EmailAddress(name: nil, mailbox: "alice", host: "x.cabalmail.example")
        try await outbox.enqueue(OutgoingMessage(from: sender, to: [sender], subject: "queued"))

        await client.clearLocalData()

        let lines = reported()
        XCTAssertEqual(lines.count, 1, "\(lines)")
        XCTAssertEqual(lines.first?.level, .error)
        XCTAssertTrue(lines.first?.message.hasPrefix("outbox not cleared") ?? false, "\(lines)")
        let queued = try await outbox.count()
        XCTAssertEqual(queued, 1, "precondition: the removal really failed")
        // Best-effort still: the steps around the failed one ran.
        let snapshot = await client.envelopeCache.snapshot(for: "INBOX")
        XCTAssertNil(snapshot)
        let body = await client.bodyCache.fetch(folder: "INBOX", uidValidity: 1, uid: 1)
        XCTAssertNil(body)
    }

    /// The mail itself. The caches' own `try?` hid this one even from the
    /// wipe: the directory was recreated over what could not be removed.
    func testAWipeWhoseMailCachesCannotBeRemovedSaysSoForEach() async throws {
        // One refusing manager each: a cache is an actor and keeps the one
        // it is handed.
        let client = try makeClient(
            envelopeCache: EnvelopeCache(
                directory: root.appendingPathComponent("envelopes"), fileManager: RefusingFileManager(token: token)
            ),
            bodyCache: MessageBodyCache(
                directory: root.appendingPathComponent("bodies"), fileManager: RefusingFileManager(token: token)
            )
        )
        try await seedMail(in: client)

        await client.clearLocalDataEndingSession()

        let names = reported().map { $0.message.components(separatedBy: " not cleared").first ?? "" }
        XCTAssertEqual(names, ["saved message lists", "saved message bodies"])
    }

    func testAWipeThatWorksReportsNothing() async throws {
        let client = try makeClient()
        try await seedMail(in: client)
        let before = Set(wipeLines().map(\.id))

        await client.clearLocalDataEndingSession()

        let snapshot = await client.envelopeCache.snapshot(for: "INBOX")
        XCTAssertNil(snapshot)
        // Tests in this process run one at a time, so a wipe line that is
        // new is this wipe's.
        let new = wipeLines().filter { !before.contains($0.id) }
        XCTAssertEqual(new.map(\.message), [])
    }

    // MARK: - The feed store

    // Whole-client tests on a real feed store, on macOS only for the reason
    // `FeedStoreSignOutTests` gives: the wipe empties the Spotlight index,
    // which stalls on a simulator with no host app. The clients above come
    // from the plain initializer, which has no feed store, so their wipes
    // never ran the feeds step at all; that is how the report below went
    // unseen until a sign-out on a device (#2568).
    #if os(macOS)
    /// An ordinary sign-out. The ending session's store is retired, which
    /// clears it and closes it, and the wipe then cleared it a second time:
    /// that attempt failed on the closed database and said the feeds might
    /// still be on the device, on every sign-out.
    func testAHealthySignOutWipeWithAFeedStoreReportsNothing() async throws {
        let client = try makeFactoryClient()
        let store = try XCTUnwrap(client.rssStore)
        try await store.upsertSubscription(RssSubscription(subscriptionId: "s1", feedId: "f1"))
        let before = Set(wipeLines().map(\.id))

        await client.clearLocalDataEndingSession()

        let new = wipeLines().filter { !before.contains($0.id) }
        XCTAssertEqual(new.map(\.message), [])
        // The feeds did go, and the store is retired.
        let next = try RssStore(directory: root.appendingPathComponent("rss"))
        let left = try await next.subscriptions()
        XCTAssertEqual(left, [])
        do {
            try await store.upsertSubscription(RssSubscription(subscriptionId: "s2", feedId: "f2"))
            XCTFail("the ending session's store took a write after the wipe")
        } catch {}
        await client.shutdown()
    }

    /// The control: a client that carries on clears its feeds in the wipe
    /// itself, and a healthy one reports nothing either.
    func testAHealthyWipeThatKeepsTheSessionClearsTheFeedsAndReportsNothing() async throws {
        let client = try makeFactoryClient()
        let store = try XCTUnwrap(client.rssStore)
        try await store.upsertSubscription(RssSubscription(subscriptionId: "s1", feedId: "f1"))
        let before = Set(wipeLines().map(\.id))

        await client.clearLocalData()

        let new = wipeLines().filter { !before.contains($0.id) }
        XCTAssertEqual(new.map(\.message), [])
        let left = try await store.subscriptions()
        XCTAssertEqual(left, [])
        await client.shutdown()
    }

    #if DEBUG
    /// A retire that really fails is still reported, and once: the failed
    /// clear inside it is the feeds step, not a first attempt at it.
    func testASignOutWipeWhoseFeedStoreCannotBeClearedSaysSoOnce() async throws {
        let client = try makeFactoryClient()
        let store = try XCTUnwrap(client.rssStore)
        try await store.upsertSubscription(RssSubscription(subscriptionId: "s1", feedId: "f1"))
        await store.failNextWipeWriteForTests()
        let before = Set(wipeLines().map(\.id))

        await client.clearLocalDataEndingSession()

        let new = wipeLines().filter { !before.contains($0.id) }
        XCTAssertEqual(new.count, 1, "\(new.map(\.message))")
        XCTAssertEqual(new.first?.level, .error)
        XCTAssertTrue(new.first?.message.hasPrefix("feed store (retiring) not cleared") ?? false, "\(new)")
        await client.shutdown()
    }
    #endif

    /// A client as the app builds one, feed store included.
    private func makeFactoryClient() throws -> CabalmailClient {
        try CabalmailClient.make(
            configuration: TestFixtures.makeConfiguration(),
            secureStore: InMemorySecureStore(),
            httpTransport: ScriptedHTTPTransport { _ in throw CabalmailError.network("offline") },
            cacheDirectory: root
        )
    }
    #endif

    // MARK: - The caches

    func testClearingAnEnvelopeCacheThatCannotBeRemovedThrowsAndLeavesItUsable() async throws {
        let cache = try EnvelopeCache(
            directory: root.appendingPathComponent("envelopes"), fileManager: RefusingFileManager(token: token)
        )
        let changes = await cache.changes()

        do {
            try await cache.clearAll()
            XCTFail("a removal that failed was not reported")
        } catch {
            XCTAssertTrue("\(error)".contains(token), "\(error)")
        }
        // The clear is still announced, and the cache still stores.
        var announced = changes.makeAsyncIterator()
        let first = await announced.next()
        if case .cleared? = first {} else { XCTFail("the clear was not announced: \(String(describing: first))") }
        try await cache.store(
            EnvelopeCache.Snapshot(uidValidity: 1, uidNext: 2, envelopes: [1: TestFixtures.makeEnvelope(uid: 1)]),
            for: "INBOX"
        )
    }

    func testClearingABodyCacheThatCannotBeRemovedThrows() async throws {
        let cache = try MessageBodyCache(
            directory: root.appendingPathComponent("bodies"), fileManager: RefusingFileManager(token: token)
        )

        do {
            try await cache.clearAll()
            XCTFail("a removal that failed was not reported")
        } catch {
            XCTAssertTrue("\(error)".contains(token), "\(error)")
        }
    }

    /// Nothing to remove is cleared, not a failure: a cache whose directory
    /// is already gone clears without throwing and comes back usable.
    func testClearingACacheWhoseDirectoryIsAlreadyGoneDoesNotThrow() async throws {
        let envelopes = root.appendingPathComponent("envelopes")
        let bodies = root.appendingPathComponent("bodies")
        let envelopeCache = try EnvelopeCache(directory: envelopes)
        let bodyCache = try MessageBodyCache(directory: bodies)
        try FileManager.default.removeItem(at: envelopes)
        try FileManager.default.removeItem(at: bodies)

        try await envelopeCache.clearAll()
        try await bodyCache.clearAll()

        XCTAssertTrue(FileManager.default.fileExists(atPath: envelopes.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bodies.path))
    }

    func testRemovingAPathThatIsAlreadyGoneIsNotAFailure() {
        let missing = root.appendingPathComponent("never-written.json")
        XCTAssertNil(WipeReport.remove(missing, using: .default))
        XCTAssertNotNil(WipeReport.remove(missing, using: RefusingFileManager(token: token)))
    }

    // MARK: - Helpers

    /// This test's wipe lines: the ones carrying its token.
    private func reported() -> [DebugLogStore.Entry] {
        wipeLines().filter { $0.message.contains(token) }
    }

    private func wipeLines() -> [DebugLogStore.Entry] {
        DebugLogStore.shared.snapshot().filter { $0.category == WipeReport.category }
    }

    private func seedMail(in client: CabalmailClient) async throws {
        try await client.envelopeCache.store(
            EnvelopeCache.Snapshot(uidValidity: 1, uidNext: 2, envelopes: [1: TestFixtures.makeEnvelope(uid: 1)]),
            for: "INBOX"
        )
        try await client.bodyCache.store(folder: "INBOX", uidValidity: 1, uid: 1, bytes: Data("raw".utf8))
    }

    private func makeClient(
        envelopeCache: EnvelopeCache? = nil, bodyCache: MessageBodyCache? = nil, outbox: Outbox? = nil
    ) throws -> CabalmailClient {
        let configuration = TestFixtures.makeConfiguration()
        let auth = NullAuthService()
        return CabalmailClient(
            configuration: configuration,
            authService: auth,
            apiClient: URLSessionApiClient(
                configuration: configuration, authService: auth, transport: NullHTTPTransport()
            ),
            imapClient: FakeImapClient(),
            addressCache: AddressCache(),
            envelopeCache: try envelopeCache ?? EnvelopeCache(directory: root.appendingPathComponent("envelopes")),
            bodyCache: try bodyCache ?? MessageBodyCache(directory: root.appendingPathComponent("bodies")),
            draftStore: try DraftStore(directory: root.appendingPathComponent("drafts")),
            outbox: try outbox ?? Outbox(directory: root.appendingPathComponent("outbox"))
        )
    }
}

/// A `FileManager` that refuses every removal, naming `token` in the error.
private final class RefusingFileManager: FileManager {
    private struct Refusal: Error, CustomStringConvertible {
        let description: String
    }

    private let token: String

    init(token: String) {
        self.token = token
        super.init()
    }

    override func removeItem(at url: URL) throws {
        throw Refusal(description: "removal refused (\(token))")
    }
}

#if DEBUG
private extension RssStore {
    /// Arms this store's connection to fail its next write to a table the
    /// clear empties, so the clear, and the retire around it, throws.
    func failNextWipeWriteForTests() {
        database.faults.arm(table: "folders")
    }
}
#endif

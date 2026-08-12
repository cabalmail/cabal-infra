import XCTest
import CoreSpotlight
import UniformTypeIdentifiers
@testable import CabalmailKit

/// Records every `SearchableIndexing` operation for assertions. An actor so
/// the indexer's concurrent sweep tasks can't race the recording.
actor FakeSearchableIndex: SearchableIndexing {
    nonisolated var isAvailable: Bool { true }

    private(set) var indexedBatches: [[SpotlightEntry]] = []
    private(set) var deletedIdentifiers: [[String]] = []
    private(set) var deletedDomains: [[String]] = []
    private(set) var deleteAllCount = 0

    var indexedEntries: [SpotlightEntry] { indexedBatches.flatMap { $0 } }

    func index(_ entries: [SpotlightEntry]) async throws {
        indexedBatches.append(entries)
    }

    func deleteIdentifiers(_ identifiers: [String]) async throws {
        deletedIdentifiers.append(identifiers)
    }

    func deleteDomains(_ domains: [String]) async throws {
        deletedDomains.append(domains)
    }

    func deleteAll() async throws {
        deleteAllCount += 1
    }
}

final class SpotlightIndexerTests: XCTestCase {
    private var fake: FakeSearchableIndex!
    private var indexer: SpotlightIndexer!

    override func setUp() async throws {
        fake = FakeSearchableIndex()
        indexer = SpotlightIndexer(index: fake)
    }

    private func envelope(uid: UInt32, subject: String? = nil) -> Envelope {
        Envelope(
            uid: uid,
            messageId: "<\(uid)@example.test>",
            date: Date(timeIntervalSince1970: TimeInterval(uid)),
            subject: subject,
            from: [EmailAddress(name: "Alice", mailbox: "alice", host: "example.test")]
        )
    }

    // MARK: - Identifier codec

    func testRefRoundTripsPlainFolder() {
        let ref = SpotlightMessageRef(folder: "INBOX", uid: 42)
        XCTAssertEqual(SpotlightMessageRef(string: ref.stringValue), ref)
    }

    func testRefRoundTripsHostileFolderNames() {
        for folder in ["Work/2026", "a|b|c", "Émeraude 📬", "trailing "] {
            let ref = SpotlightMessageRef(folder: folder, uid: UInt32.max)
            XCTAssertEqual(SpotlightMessageRef(string: ref.stringValue), ref, folder)
        }
    }

    func testRefRejectsForeignIdentifiers() {
        XCTAssertNil(SpotlightMessageRef(string: ""))
        XCTAssertNil(SpotlightMessageRef(string: "com.example.other-app-item"))
        XCTAssertNil(SpotlightMessageRef(string: "cabalmail-msg|v0|SU5CT1g|1"))
        XCTAssertNil(SpotlightMessageRef(string: "cabalmail-msg|v1|SU5CT1g"))
        XCTAssertNil(SpotlightMessageRef(string: "cabalmail-msg|v1|SU5CT1g|not-a-uid"))
        XCTAssertNil(SpotlightMessageRef(string: "cabalmail-msg|v1|%%%|1"))
    }

    // MARK: - Entry building

    func testEntryFallsBackToNoSubjectTitle() {
        let entry = SpotlightEntry(envelope: envelope(uid: 1, subject: "  "), folder: "INBOX")
        XCTAssertEqual(entry.title, "(No subject)")
    }

    func testEntryCarriesAuthorAndDomain() {
        let entry = SpotlightEntry(envelope: envelope(uid: 1, subject: "Hi"), folder: "Work/2026")
        XCTAssertEqual(entry.title, "Hi")
        XCTAssertEqual(entry.authorNames, ["Alice"])
        XCTAssertEqual(entry.authorEmailAddresses, ["alice@example.test"])
        XCTAssertEqual(entry.domainIdentifier, "Work/2026")
        XCTAssertEqual(entry.contentDescription, "Alice")
    }

    func testEntrySnippetCollapsesWhitespace() {
        let entry = SpotlightEntry(
            envelope: envelope(uid: 1, subject: "Hi"),
            folder: "INBOX",
            textContent: "  line one\n\n\tline   two  "
        )
        XCTAssertEqual(entry.contentDescription, "line one line two")
    }

    // MARK: - CSSearchableItem mapping

    /// Regression guards for two empirically painful platform behaviors:
    /// macOS routes email-typed results to Apple Mail regardless of
    /// CoreSpotlightContinuation, and iOS 17+ hides items whose attribute
    /// set lacks `displayName`. See `SpotlightEntry.searchableItem()`.
    func testSearchableItemAvoidsMailRoutedContentTypes() {
        let item = SpotlightEntry(envelope: envelope(uid: 1, subject: "Hi"), folder: "INBOX")
            .searchableItem()
        let contentType = item.attributeSet.contentType
        XCTAssertNotEqual(contentType, UTType.emailMessage.identifier)
        XCTAssertNotEqual(contentType, UTType.message.identifier)
        XCTAssertEqual(contentType, UTType.text.identifier)
    }

    func testSearchableItemSetsDisplayNameAndDefaultExpiration() {
        let item = SpotlightEntry(envelope: envelope(uid: 1, subject: "Hi"), folder: "INBOX")
            .searchableItem()
        XCTAssertEqual(item.attributeSet.displayName, "Hi")
        XCTAssertEqual(item.attributeSet.title, "Hi")
        // `.distantFuture` has a history of making items invisible; the
        // default expiry (refreshed by the session sweep) must stand.
        XCTAssertNotEqual(item.expirationDate, .distantFuture)
    }

    // MARK: - Schema migration

    func testFirstSweepWipesIndexOnceForSchemaChange() async throws {
        let suiteName = "spotlight-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let indexer = SpotlightIndexer(index: fake, defaults: defaults)
        let imap = SweepFakeImapClient(folders: [], envelopesByFolder: [:])
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cabalmail-spotlight-schema-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let cache = try EnvelopeCache(directory: tempDir)

        await indexer.sweep(imap: imap, envelopeCache: cache)
        var wipes = await fake.deleteAllCount
        XCTAssertEqual(wipes, 1)
        XCTAssertEqual(
            defaults.integer(forKey: "cabalmail.spotlight.schemaVersion"),
            SpotlightIndexer.schemaVersion
        )

        await indexer.sweep(imap: imap, envelopeCache: cache)
        wipes = await fake.deleteAllCount
        XCTAssertEqual(wipes, 1, "marker persisted; second sweep must not wipe again")
    }

    // MARK: - Subscription gating

    func testUpsertsDroppedWhileSubscriptionUnknown() async {
        await indexer.indexEnvelopes([envelope(uid: 1)], folder: "INBOX")
        let batches = await fake.indexedBatches
        XCTAssertTrue(batches.isEmpty)
    }

    func testUpsertsIndexOnlySubscribedFolders() async {
        await indexer.setSubscribedFolders(["INBOX"])
        await indexer.indexEnvelopes([envelope(uid: 1)], folder: "INBOX")
        await indexer.indexEnvelopes([envelope(uid: 2)], folder: "Junk")
        let entries = await fake.indexedEntries
        XCTAssertEqual(entries.map(\.ref.uid), [1])
        XCTAssertEqual(entries.map(\.ref.folder), ["INBOX"])
    }

    func testRemovalAppliesRegardlessOfSubscription() async {
        await indexer.removeMessages(uids: [7, 8], folder: "Junk")
        let deleted = await fake.deletedIdentifiers
        XCTAssertEqual(deleted, [[
            SpotlightMessageRef(folder: "Junk", uid: 7).stringValue,
            SpotlightMessageRef(folder: "Junk", uid: 8).stringValue,
        ]])
    }

    func testUnsubscribePurgesDomainAndBlocksFutureUpserts() async {
        await indexer.setSubscribedFolders(["INBOX", "Work"])
        await indexer.noteSubscription(folder: "Work", isSubscribed: false)
        await indexer.indexEnvelopes([envelope(uid: 1)], folder: "Work")
        let domains = await fake.deletedDomains
        let batches = await fake.indexedBatches
        XCTAssertEqual(domains, [["Work"]])
        XCTAssertTrue(batches.isEmpty)
    }

    func testSetSubscribedFoldersPurgesDroppedFolders() async {
        await indexer.setSubscribedFolders(["INBOX", "Work"])
        await indexer.setSubscribedFolders(["INBOX"])
        let domains = await fake.deletedDomains
        XCTAssertEqual(domains, [["Work"]])
    }

    // MARK: - Body text

    func testBodyTextSurvivesEnvelopeReindex() async {
        await indexer.setSubscribedFolders(["INBOX"])
        let message = envelope(uid: 5, subject: "Receipt")
        await indexer.indexBody(text: "Your total is $12", envelope: message, folder: "INBOX")
        // A later flag-refresh upsert of the same envelope must keep the
        // donated body text (Spotlight replaces the whole attribute set).
        await indexer.indexEnvelopes([message], folder: "INBOX")
        let entries = await fake.indexedEntries
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries.last?.textContent, "Your total is $12")
    }

    func testBodyIndexRespectsSubscriptionGate() async {
        await indexer.setSubscribedFolders(["INBOX"])
        await indexer.indexBody(text: "secret", envelope: envelope(uid: 1), folder: "Junk")
        let batches = await fake.indexedBatches
        XCTAssertTrue(batches.isEmpty)
    }

    // MARK: - Cache feed

    func testBoundCacheFeedIndexesMergesAndPurgesRemovals() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cabalmail-spotlight-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let cache = try EnvelopeCache(directory: tempDir)
        await indexer.setSubscribedFolders(["INBOX"])
        let indexer = self.indexer!
        let bindTask = Task { await indexer.bind(to: cache) }
        defer { bindTask.cancel() }
        // Give bind a beat to subscribe before the first mutation.
        try await waitUntil { await cache.hasChangeObservers }

        try await cache.merge(
            envelopes: [envelope(uid: 1), envelope(uid: 2)],
            uidValidity: 100, uidNext: 3, into: "INBOX"
        )
        try await waitUntil { await self.fake.indexedEntries.count == 2 }

        try await cache.remove(uids: [1], folder: "INBOX")
        try await waitUntil { await self.fake.deletedIdentifiers.count == 1 }
        let deleted = await fake.deletedIdentifiers
        XCTAssertEqual(deleted, [[SpotlightMessageRef(folder: "INBOX", uid: 1).stringValue]])

        try await cache.invalidate(folder: "INBOX")
        try await waitUntil { await self.fake.deletedDomains.contains(["INBOX"]) }

        try await cache.clearAll()
        try await waitUntil { await self.fake.deleteAllCount == 1 }
    }

    // MARK: - Sweep

    func testSweepIndexesSubscribedFoldersThroughCache() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cabalmail-spotlight-sweep-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let cache = try EnvelopeCache(directory: tempDir)
        let indexer = self.indexer!
        let bindTask = Task { await indexer.bind(to: cache) }
        defer { bindTask.cancel() }
        try await waitUntil { await cache.hasChangeObservers }

        let imap = SweepFakeImapClient(
            folders: [
                Folder(path: "INBOX", isSubscribed: true),
                Folder(path: "Work", isSubscribed: true),
                Folder(path: "Junk", isSubscribed: false),
            ],
            envelopesByFolder: [
                "INBOX": [envelope(uid: 1, subject: "one")],
                "Work": [envelope(uid: 9, subject: "nine")],
                "Junk": [envelope(uid: 66, subject: "spam")],
            ]
        )
        await indexer.sweep(imap: imap, envelopeCache: cache)
        try await waitUntil { await self.fake.indexedEntries.count == 2 }
        let entries = await fake.indexedEntries
        XCTAssertEqual(Set(entries.map(\.ref.folder)), ["INBOX", "Work"])
        // The sweep warms the offline envelope cache too.
        let inbox = await cache.snapshot(for: "INBOX")
        XCTAssertEqual(Array(inbox?.envelopes.keys ?? [:].keys), [1])
    }

    // MARK: - Helpers

    private func waitUntil(
        _ condition: @escaping () async -> Bool,
        timeout: TimeInterval = 5
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("timed out waiting for condition")
    }
}

/// Minimal `ImapClient` for the sweep test: a folder list, one page of
/// envelopes per folder, and throwing stubs for everything the sweep never
/// touches.
private struct SweepFakeImapClient: ImapClient {
    let folders: [Folder]
    let envelopesByFolder: [String: [Envelope]]

    func connectAndAuthenticate() async throws {}
    func listFolders() async throws -> [Folder] { folders }
    func createFolder(name: String, parent: String?) async throws { throw CabalmailError.cancelled }
    func deleteFolder(path: String) async throws { throw CabalmailError.cancelled }
    func subscribe(path: String) async throws { throw CabalmailError.cancelled }
    func unsubscribe(path: String) async throws { throw CabalmailError.cancelled }

    func status(path: String, flagged: Bool) async throws -> FolderStatus {
        FolderStatus(
            messages: envelopesByFolder[path]?.count ?? 0,
            unseen: 0,
            uidValidity: 100,
            uidNext: 1000
        )
    }

    func envelopes(
        folder: String, range: ClosedRange<UInt32>, sort: SortCriterion
    ) async throws -> [Envelope] { throw CabalmailError.cancelled }

    func topEnvelopes(
        folder: String, limit: UInt32, totalMessages: UInt32, sort: SortCriterion
    ) async throws -> [Envelope] {
        envelopesByFolder[folder] ?? []
    }

    func fetchBody(folder: String, uid: UInt32) async throws -> RawMessage {
        throw CabalmailError.cancelled
    }
    func fetchPart(folder: String, uid: UInt32, partId: String) async throws -> Data {
        throw CabalmailError.cancelled
    }
    func setFlags(
        folder: String, uids: [UInt32], flags: Set<Flag>, operation: FlagOperation
    ) async throws { throw CabalmailError.cancelled }
    func move(
        folder: String, uids: [UInt32], destination: String, markSeen: Bool
    ) async throws { throw CabalmailError.cancelled }
    func append(folder: String, message: Data, flags: Set<Flag>) async throws {
        throw CabalmailError.cancelled
    }
    func disconnect() async {}
    func invalidate() async {}
}

import XCTest
import CabalmailKit
@testable import CabalmailUI

// Shared fixture for the reader-open characterization suites of workstream
// 0.8 (`MessageDetailViewModel.load()`, the body cache it reads and fills,
// and mark-as-read on open). See `MessageDetailLoadTests` for what they
// protect.

/// Readers over the fake transport for the reader-open suites
/// (`MessageDetailLoadTests`, `MessageDetailLoadFailureTests`,
/// `MessageDetailMarkSeenTests`). Each client caches under its own temp
/// directory; `cleanUp()` removes those, and the attachment directories the
/// readers wrote (found through the attachments' `fileURL`s).
@MainActor
final class MessageDetailLoadFixture {
    /// The UIDVALIDITY every seeded snapshot carries.
    let uidValidity: UInt32 = 42
    private var clientRoots: [URL] = []
    private var readers: [MessageDetailViewModel] = []

    /// A memberwise client (no Spotlight, no reachability) whose caches this
    /// fixture removes.
    func makeClient(imap: FakeImapClient) async throws -> CabalmailClient {
        let client = try TestFixtures.makeClient(imap: imap)
        await track(client)
        return client
    }

    /// A client whose folder-state cache has a directory, so a STATUS
    /// recorded with `saveFolderStatus` is read back the way an earlier
    /// online session would have left it.
    func makeClientSavingFolderState(imap: FakeImapClient) async throws -> CabalmailClient {
        let folderRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("detail-folder-state-\(UUID().uuidString)")
        clientRoots.append(folderRoot)
        let client = try TestFixtures.makeClient(imap: imap, folderStateCache: FolderStateCache(directory: folderRoot))
        await track(client)
        return client
    }

    /// What an earlier online session saved for `folder`: its UIDVALIDITY.
    func saveFolderStatus(_ client: CabalmailClient, folder: String = "INBOX", uidValidity: UInt32? = nil) async {
        let generation = await client.folderStateCache.generation
        await client.folderStateCache.recordStatus(
            FolderStatus(messages: 1, uidValidity: uidValidity ?? self.uidValidity),
            for: folder,
            ifUnchangedSince: generation
        )
    }

    /// Registers a client built elsewhere (a list model's) for cleanup.
    func track(_ client: CabalmailClient) async {
        clientRoots.append(await client.bodyCache.directory.deletingLastPathComponent())
    }

    func makeReader(
        imap: FakeImapClient,
        uid: UInt32,
        flags: Set<Flag> = [],
        folderPath: String = "INBOX",
        markAsRead: MarkAsReadBehavior = .manual,
        client: CabalmailClient? = nil
    ) async throws -> MessageDetailViewModel {
        try await makeReader(
            imap: imap,
            envelope: TestFixtures.makeEnvelope(uid: uid, flags: flags),
            folderPath: folderPath,
            markAsRead: markAsRead,
            client: client
        )
    }

    func makeReader(
        imap: FakeImapClient,
        envelope: Envelope,
        folderPath: String = "INBOX",
        markAsRead: MarkAsReadBehavior = .manual,
        client: CabalmailClient? = nil
    ) async throws -> MessageDetailViewModel {
        let preferences = Preferences(store: InMemoryPreferenceStore())
        preferences.markAsRead = markAsRead
        let resolvedClient: CabalmailClient
        if let client {
            resolvedClient = client
        } else {
            resolvedClient = try await makeClient(imap: imap)
        }
        let reader = MessageDetailViewModel(
            folder: Folder(path: folderPath, attributes: [], isSubscribed: true),
            envelope: envelope,
            client: resolvedClient,
            preferences: preferences
        )
        readers.append(reader)
        return reader
    }

    /// Seeds the reader's folder snapshot -- where the reader takes the
    /// UIDVALIDITY that keys the body cache -- holding `envelopes` (by
    /// default just the open message).
    func seedSnapshot(_ model: MessageDetailViewModel, envelopes: [Envelope]? = nil) async throws {
        try await seedSnapshot(
            client: model.client,
            folder: model.folder.path,
            envelopes: envelopes ?? [model.envelope]
        )
    }

    func seedSnapshot(client: CabalmailClient, folder: String, envelopes: [Envelope]) async throws {
        try await client.envelopeCache.store(
            EnvelopeCache.Snapshot(
                uidValidity: uidValidity,
                uidNext: (envelopes.map(\.uid).max() ?? 0) + 1,
                envelopes: Dictionary(uniqueKeysWithValues: envelopes.map { ($0.uid, $0) })
            ),
            for: folder
        )
    }

    func cacheBody(_ bytes: Data, for model: MessageDetailViewModel, uidValidity: UInt32? = nil) async throws {
        try await model.client.bodyCache.store(
            folder: model.folder.path,
            uidValidity: uidValidity ?? self.uidValidity,
            uid: model.envelope.uid,
            bytes: bytes
        )
    }

    func cachedBody(for model: MessageDetailViewModel, uidValidity: UInt32? = nil) async -> Data? {
        await model.client.bodyCache.fetch(
            folder: model.folder.path,
            uidValidity: uidValidity ?? self.uidValidity,
            uid: model.envelope.uid
        )
    }

    func cleanUp() {
        let fileManager = FileManager.default
        for root in clientRoots {
            try? fileManager.removeItem(at: root)
        }
        // Only the directories these readers wrote, found through each
        // attachment's own `fileURL` rather than by rebuilding the reader's
        // private naming, so a change to how that directory is keyed still
        // gets cleaned up.
        let attachmentDirectories = Set(readers.flatMap { reader in
            reader.attachments.map { $0.fileURL.deletingLastPathComponent() }
        })
        for directory in attachmentDirectories {
            try? fileManager.removeItem(at: directory)
        }
    }

    /// Each recorded `fetchBody` as "folder#uid", in order.
    static func fetchKeys(_ imap: FakeImapClient) async -> [String] {
        await imap.fetchBodyCalls.map { "\($0.folder)#\($0.uid)" }
    }

    /// Returns once every job already queued on the main actor has run to
    /// its first suspension. The main actor drains its queue in order, so a
    /// task the code under test spawned before this call (the reader's
    /// `Task { await setSeen(true) }`, a second `load()`) has taken its
    /// synchronous first step by then. Used to show that no such task was
    /// spawned, without a fixed sleep.
    ///
    /// The barrier proves absence only for work spawned onto the main actor,
    /// which holds today: `scheduleMarkAsReadIfNeeded` and
    /// `startLoadIfNeeded` are `@MainActor` and spawn main-actor tasks. If
    /// the refactor moves mark-seen or the load into a store actor or a
    /// detached task, the negative tests that use this barrier must be
    /// revisited, or they would pass by winning a race.
    static func drainMainActor() async {
        await Task { @MainActor in }.value
    }

    /// `imap.awaitHeld(call)` with a bounded wait for the call to arrive.
    /// The fake records a call and parks it at the hold in one step on its
    /// actor, so this waits (bounded, like `waitUntil`) until `count` calls
    /// of that kind are recorded, and only then awaits the gate. Returns
    /// false, having failed the test, when the call never arrives, so a
    /// regression that stops the call fails the test instead of hanging it.
    ///
    /// It can't hang only while the hold is armed for the counted call: the
    /// second wait is the fake's own, unbounded. If the counted call was
    /// recorded without parking (`holdNext` not armed, or the hold spent on
    /// an earlier call of that kind), the gate waits for an arrival that
    /// never comes. Every caller arms `holdNext` before the counted call.
    nonisolated static func awaitHeld(
        _ call: FakeImapClient.HeldCall,
        in imap: FakeImapClient,
        calls count: Int = 1,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> Bool {
        try await waitUntil(file: file, line: line) { await recordedCount(call, in: imap) >= count }
        guard await recordedCount(call, in: imap) >= count else { return false }
        await imap.awaitHeld(call)
        return true
    }

    /// Recorded calls of the kinds these suites hold. Any other kind isn't
    /// counted here, so `awaitHeld` falls straight through to the fake's gate.
    private nonisolated static func recordedCount(
        _ call: FakeImapClient.HeldCall,
        in imap: FakeImapClient
    ) async -> Int {
        switch call {
        case .fetchBody:
            return await imap.fetchBodyCalls.count
        case .setFlags:
            return await imap.flagCalls.count
        default:
            return Int.max
        }
    }
}

/// Raw RFC 5322 messages, CRLF-delimited like the presigned S3 object the
/// Lambda serves.
enum MessageDetailMimeFixture {
    static func message(_ lines: [String]) -> Data {
        Data(lines.joined(separator: "\r\n").utf8)
    }

    static let alternativePlain = "Plain body line."
    static let alternativeHTML = "<p>HTML body line.</p>"

    /// multipart/alternative with the full threading identity; References
    /// is folded across two lines.
    static let alternative = message([
        "Message-ID: <reply-1@example.com>",
        "In-Reply-To: <root-1@example.com>",
        "References: <root-0@example.com>",
        " <root-1@example.com>",
        "Subject: Characterization",
        "From: Sender <sender7@example.com>",
        "MIME-Version: 1.0",
        "Content-Type: multipart/alternative; boundary=\"alt\"",
        "",
        "--alt",
        "Content-Type: text/plain; charset=utf-8",
        "",
        alternativePlain,
        "--alt",
        "Content-Type: text/html; charset=utf-8",
        "",
        alternativeHTML,
        "--alt--",
        "",
    ])

    /// multipart/mixed: an HTML body with one inline `cid:` PNG (inside a
    /// multipart/related), one named PDF attachment and one unnamed binary.
    static let mixed = message([
        "Message-ID: <mixed-1@example.com>",
        "Subject: With attachments",
        "MIME-Version: 1.0",
        "Content-Type: multipart/mixed; boundary=\"mix\"",
        "",
        "--mix",
        "Content-Type: multipart/related; boundary=\"rel\"",
        "",
        "--rel",
        "Content-Type: text/html; charset=utf-8",
        "",
        "<p>Logo: <img src=\"cid:logo@example.com\"></p>",
        "--rel",
        "Content-Type: image/png",
        "Content-Transfer-Encoding: base64",
        "Content-ID: <logo@example.com>",
        "Content-Disposition: inline",
        "",
        "iVBORw0KGgo=",
        "--rel--",
        "--mix",
        "Content-Type: application/pdf; name=\"report.pdf\"",
        "Content-Transfer-Encoding: base64",
        "Content-Disposition: attachment; filename=\"report.pdf\"",
        "",
        "JVBERi0xLjQK",
        "--mix",
        "Content-Type: application/octet-stream",
        "Content-Transfer-Encoding: base64",
        "",
        "AAECAw==",
        "--mix--",
        "",
    ])

    /// An HTML-only body with a `text/plain` file attached.
    static let htmlWithTextAttachment = message([
        "Subject: Notes attached",
        "Content-Type: multipart/mixed; boundary=\"mix\"",
        "",
        "--mix",
        "Content-Type: text/html; charset=utf-8",
        "",
        "<p>Body</p>",
        "--mix",
        "Content-Type: text/plain; name=\"notes.txt\"",
        "Content-Disposition: attachment; filename=\"notes.txt\"",
        "",
        "attached notes",
        "--mix--",
        "",
    ])

    /// A plain-text body with one attachment, `same.bin`, holding `contents`.
    static func namedBlob(_ contents: String) -> Data {
        message([
            "Subject: Blob",
            "Content-Type: multipart/mixed; boundary=\"mix\"",
            "",
            "--mix",
            "Content-Type: text/plain",
            "",
            "See attached.",
            "--mix",
            "Content-Type: application/octet-stream",
            "Content-Disposition: attachment; filename=\"same.bin\"",
            "",
            contents,
            "--mix--",
            "",
        ])
    }
}

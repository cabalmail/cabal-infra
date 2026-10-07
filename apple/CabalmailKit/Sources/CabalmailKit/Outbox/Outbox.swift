import Foundation

/// Disk-persisted queue of outgoing messages that failed transport.
///
/// Phase 7 plan: "composed messages queue and send (or APPEND to Drafts)
/// on reconnect." This is the queue half — the `SendQueue` actor drains
/// it once reachability returns. Messages land here as a fallback from
/// `CabalmailClient.send(_:)` when the SMTP submission fails with a
/// transport / network error. Application-level rejections (auth failure,
/// invalid recipient) are surfaced to the user immediately and never
/// queued.
///
/// Persistence format: one JSON file per entry under `directory/`, keyed
/// by UUID — mirrors `DraftStore`'s layout so a corrupt entry only takes
/// itself out. The enclosed `OutgoingMessage` is the same value the SMTP
/// client already serializes, plus a small wrapper that tracks retry
/// state so failing sends don't spin forever. Each file is a
/// `PersistedRecord` (schema-versioned); a file that can't be read is moved
/// to `quarantine/` rather than deleted.
///
/// An entry that exhausts its retries is kept, marked `failedAt`, and no
/// longer drained: the app shows it to the user, who can retry or discard
/// it. `changes()` streams the entries so that UI stays current.
public actor Outbox {
    /// Bump when `Entry`'s persisted shape changes, and teach `list()` to
    /// migrate the older version.
    static let schemaVersion = 1

    public struct Entry: Sendable, Codable, Identifiable, Hashable {
        public let id: UUID
        public let enqueuedAt: Date
        public var attempts: Int
        public var lastAttemptAt: Date?
        public var lastError: String?
        /// Set when the entry ran out of retries. A failed entry stays in
        /// the outbox, undrained, until the user retries or discards it.
        public var failedAt: Date?
        public let message: OutgoingMessage

        public var isFailed: Bool { failedAt != nil }

        public init(
            id: UUID = UUID(),
            enqueuedAt: Date = Date(),
            attempts: Int = 0,
            lastAttemptAt: Date? = nil,
            lastError: String? = nil,
            failedAt: Date? = nil,
            message: OutgoingMessage
        ) {
            self.id = id
            self.enqueuedAt = enqueuedAt
            self.attempts = attempts
            self.lastAttemptAt = lastAttemptAt
            self.lastError = lastError
            self.failedAt = failedAt
            self.message = message
        }
    }

    public nonisolated let directory: URL
    public nonisolated let maxAttempts: Int
    private let fileManager: FileManager
    private var observers: [UUID: AsyncStream<[Entry]>.Continuation] = [:]

    public init(
        directory: URL,
        maxAttempts: Int = 10,
        fileManager: FileManager = .default
    ) throws {
        self.directory = directory
        self.maxAttempts = maxAttempts
        self.fileManager = fileManager
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
    }

    /// Persists a fresh entry. The returned value contains the generated
    /// id so callers can report "your message is in the outbox (n)."
    @discardableResult
    public func enqueue(_ message: OutgoingMessage) throws -> Entry {
        let entry = Entry(message: message)
        try store(entry)
        return entry
    }

    /// Returns the queue sorted by `enqueuedAt` ascending (oldest first),
    /// failed entries included. Drainers call this repeatedly — cheap
    /// because it's just a directory scan and per-file decode.
    ///
    /// A file that can't be decoded is quarantined, not deleted; one
    /// written by a newer build (a higher schema version) is skipped and
    /// left in place.
    public func list() throws -> [Entry] {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else {
            return []
        }
        var entries: [Entry] = []
        for url in urls where url.pathExtension == "json" {
            let data: Data
            do {
                data = try Data(contentsOf: url)
            } catch {
                RecordQuarantine.quarantine(url, reason: error, category: "Outbox", fileManager: fileManager)
                continue
            }
            switch PersistedRecordCoding.read(
                Entry.self, from: data, currentVersion: Self.schemaVersion, decoder: decoder
            ) {
            case .decoded(let entry):
                entries.append(entry)
            case .newerSchema(let version):
                CabalmailLog.warn(
                    "Outbox",
                    "skipping \(url.lastPathComponent): schema \(version) is newer than this build"
                )
            case .undecodable(let error):
                RecordQuarantine.quarantine(url, reason: error, category: "Outbox", fileManager: fileManager)
            }
        }
        return entries.sorted { $0.enqueuedAt < $1.enqueuedAt }
    }

    /// Entries that ran out of retries and are waiting on the user.
    public func failed() throws -> [Entry] {
        try list().filter(\.isFailed)
    }

    public func remove(id: UUID) throws {
        let url = fileURL(for: id)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
            notifyObservers()
        }
    }

    /// Rewrites an entry that is still queued, and returns whether it was.
    /// An entry removed in the meantime stays removed: an attempt that
    /// outlived its entry (the outbox wiped by a sign-out while a drain's
    /// send was in flight, or the message discarded) must not write it back,
    /// or the next account's queue would send the previous account's mail
    /// (#1909).
    @discardableResult
    public func update(_ entry: Entry) throws -> Bool {
        guard fileManager.fileExists(atPath: fileURL(for: entry.id).path) else { return false }
        try store(entry)
        return true
    }

    /// Puts a failed entry back in the queue with a fresh retry budget. The
    /// caller kicks a drain (`CabalmailClient.retryFailedSend(id:)`).
    @discardableResult
    public func resetForRetry(id: UUID) throws -> Entry? {
        guard var entry = try list().first(where: { $0.id == id }) else { return nil }
        entry.attempts = 0
        entry.lastAttemptAt = nil
        entry.lastError = nil
        entry.failedAt = nil
        try store(entry)
        return entry
    }

    /// Removes everything in the outbox, including unreadable and
    /// quarantined files. Sign-out uses this, so nothing of the previous
    /// account's queued mail survives on disk.
    public func removeAll() throws {
        try RecordQuarantine.removeEverything(in: directory, fileManager: fileManager)
        notifyObservers()
    }

    public func count() throws -> Int {
        try list().count
    }

    /// Streams the outbox's entries: the current list on subscription, then
    /// the list after every enqueue, update and removal. The app's
    /// failed-send banner reads this.
    public func changes() -> AsyncStream<[Entry]> {
        let (stream, continuation) = AsyncStream<[Entry]>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let token = UUID()
        observers[token] = continuation
        continuation.onTermination = { @Sendable [weak self] _ in
            guard let self else { return }
            Task { await self.removeObserver(token) }
        }
        continuation.yield((try? list()) ?? [])
        return stream
    }

    // MARK: - Internals

    private func store(_ entry: Entry) throws {
        let data = try PersistedRecordCoding.encode(entry, version: Self.schemaVersion, encoder: encoder)
        try data.write(to: fileURL(for: entry.id), options: .atomic)
        notifyObservers()
    }

    private func notifyObservers() {
        guard !observers.isEmpty else { return }
        let entries = (try? list()) ?? []
        for continuation in observers.values {
            continuation.yield(entries)
        }
    }

    private func removeObserver(_ token: UUID) {
        observers[token] = nil
    }

    private func fileURL(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    private var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }

    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }
}

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
/// state so failing sends don't spin forever.
public actor Outbox {
    public struct Entry: Sendable, Codable, Identifiable, Hashable {
        public let id: UUID
        public let enqueuedAt: Date
        public var attempts: Int
        public var lastAttemptAt: Date?
        public var lastError: String?
        public let message: OutgoingMessage

        public init(
            id: UUID = UUID(),
            enqueuedAt: Date = Date(),
            attempts: Int = 0,
            lastAttemptAt: Date? = nil,
            lastError: String? = nil,
            message: OutgoingMessage
        ) {
            self.id = id
            self.enqueuedAt = enqueuedAt
            self.attempts = attempts
            self.lastAttemptAt = lastAttemptAt
            self.lastError = lastError
            self.message = message
        }
    }

    public nonisolated let directory: URL
    public nonisolated let maxAttempts: Int
    private let fileManager: FileManager

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

    /// Returns the queue sorted by `enqueuedAt` ascending (oldest first).
    /// Drainers call this repeatedly — cheap because it's just a directory
    /// scan and per-file decode.
    public func list() throws -> [Entry] {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else {
            return []
        }
        var entries: [Entry] = []
        for url in urls where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let entry = try? decoder.decode(Entry.self, from: data) else {
                try? fileManager.removeItem(at: url)
                continue
            }
            entries.append(entry)
        }
        return entries.sorted { $0.enqueuedAt < $1.enqueuedAt }
    }

    public func remove(id: UUID) throws {
        let url = fileURL(for: id)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    public func update(_ entry: Entry) throws {
        try store(entry)
    }

    /// Best-effort removal of everything in the outbox.
    public func removeAll() throws {
        for entry in try list() {
            try? remove(id: entry.id)
        }
    }

    public func count() throws -> Int {
        try list().count
    }

    // MARK: - Internals

    private func store(_ entry: Entry) throws {
        let data = try encoder.encode(entry)
        try data.write(to: fileURL(for: entry.id), options: .atomic)
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

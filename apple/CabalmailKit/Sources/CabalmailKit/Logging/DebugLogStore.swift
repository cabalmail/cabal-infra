import Foundation

/// Bounded in-memory ring buffer of recent log lines.
///
/// Phase 7 swaps anonymous `print` / ad-hoc error-message strings for a
/// structured `DebugLogStore`: every view model, transport, and watcher
/// pushes `LogEntry` records here; the Settings → Debug Log screen renders
/// the most-recent `capacity` entries. Kept in memory — crashes take it
/// with them — because the logs are a troubleshooting aid, not a durable
/// audit trail. `MetricKitCollector` funnels MetricKit crash and hang
/// payloads into the same buffer so the Settings screen shows them too.
///
/// Concurrency: an actor because writes come from every part of the app
/// (IMAP connection actor, SMTP connection actor, main-actor view models,
/// background tasks). Observers subscribe via `newEntries` — an
/// `AsyncStream<LogEntry>` — which keeps SwiftUI views up-to-date without
/// dragging an `@Observable` across actor boundaries.
public actor DebugLogStore {
    public enum Level: String, Sendable, Codable, CaseIterable {
        case debug, info, warn, error
    }

    public struct Entry: Sendable, Identifiable, Hashable {
        public let id: UUID
        public let timestamp: Date
        public let level: Level
        public let category: String
        public let message: String

        public init(
            id: UUID = UUID(),
            timestamp: Date = Date(),
            level: Level,
            category: String,
            message: String
        ) {
            self.id = id
            self.timestamp = timestamp
            self.level = level
            self.category = category
            self.message = message
        }
    }

    public static let shared = DebugLogStore()

    public let capacity: Int
    private var buffer: [Entry]
    private var continuations: [UUID: AsyncStream<Entry>.Continuation] = [:]

    public init(capacity: Int = 1000) {
        self.capacity = capacity
        self.buffer = []
        buffer.reserveCapacity(capacity)
    }

    public func append(_ entry: Entry) {
        buffer.append(entry)
        if buffer.count > capacity {
            buffer.removeFirst(buffer.count - capacity)
        }
        for continuation in continuations.values {
            continuation.yield(entry)
        }
    }

    public func log(
        _ level: Level,
        _ category: String,
        _ message: @autoclosure () -> String
    ) {
        append(Entry(level: level, category: category, message: message()))
    }

    public func snapshot() -> [Entry] { buffer }

    public func clear() {
        buffer.removeAll(keepingCapacity: true)
    }

    /// Stream of entries appended after subscription. Finishes when the
    /// caller drops the stream.
    public func newEntries() -> AsyncStream<Entry> {
        AsyncStream { continuation in
            let id = UUID()
            continuations[id] = continuation
            continuation.onTermination = { @Sendable _ in
                Task { [weak self] in
                    await self?.removeContinuation(id: id)
                }
            }
        }
    }

    private func removeContinuation(id: UUID) {
        continuations.removeValue(forKey: id)
    }
}

/// Convenience logger front — fire-and-forget.
///
/// Hot callers (parsers, SMTP state machine) use this instead of
/// `await store.log(...)` every line. The `Task` detach is safe because
/// `DebugLogStore.append` is a single actor-hop on a bounded buffer; the
/// ordering between log calls within the same isolation domain matches the
/// call order because each `Task` created here inherits it.
public enum CabalmailLog {
    public static func debug(_ category: String, _ message: @autoclosure @escaping () -> String) {
        let captured = message()
        Task { await DebugLogStore.shared.log(.debug, category, captured) }
    }

    public static func info(_ category: String, _ message: @autoclosure @escaping () -> String) {
        let captured = message()
        Task { await DebugLogStore.shared.log(.info, category, captured) }
    }

    public static func warn(_ category: String, _ message: @autoclosure @escaping () -> String) {
        let captured = message()
        Task { await DebugLogStore.shared.log(.warn, category, captured) }
    }

    public static func error(_ category: String, _ message: @autoclosure @escaping () -> String) {
        let captured = message()
        Task { await DebugLogStore.shared.log(.error, category, captured) }
    }
}

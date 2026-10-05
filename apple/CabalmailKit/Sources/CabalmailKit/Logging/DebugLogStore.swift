import Foundation
import Synchronization

/// Bounded in-memory ring buffer of recent log lines, behind the Settings →
/// Debug Log screen.
///
/// `CabalmailLog` writes every line here as well as to the unified log, so
/// the screen shows what Console would, including MetricKit's crash and hang
/// payloads (`MetricKitCollector`). Kept in memory — crashes take it with
/// them — because the logs are a troubleshooting aid, not a durable audit
/// trail.
///
/// Concurrency: the ring and the subscribers share one `Mutex`, and writes
/// are synchronous, so lines land in the order they were logged from any
/// isolation domain. Observers subscribe via `newEntries` — an
/// `AsyncStream<Entry>` — which keeps SwiftUI views up-to-date without
/// dragging an `@Observable` across actor boundaries.
public final class DebugLogStore: Sendable {
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
    private let state: Mutex<State>

    public init(capacity: Int = 1000) {
        self.capacity = capacity
        self.state = Mutex(State(capacity: capacity))
    }

    deinit {
        let observers = state.withLock { state in
            defer { state.continuations.removeAll() }
            return Array(state.continuations.values)
        }
        for continuation in observers {
            continuation.finish()
        }
    }

    /// Adds `entry`, dropping the oldest once the buffer is full, and hands it
    /// to every subscriber. Subscribers are fed under the same lock, so each
    /// sees entries in buffer order.
    public func append(_ entry: Entry) {
        state.withLock { state in
            state.ring.append(entry)
            for continuation in state.continuations.values {
                continuation.yield(entry)
            }
        }
    }

    /// Buffer-only write for tests; everything else logs through
    /// `CabalmailLog`, which also reaches the unified log.
    func log(
        _ level: Level,
        _ category: String,
        _ message: @autoclosure () -> String
    ) {
        append(Entry(level: level, category: category, message: message()))
    }

    /// The buffered entries, oldest first.
    public func snapshot() -> [Entry] {
        state.withLock { $0.ring.ordered }
    }

    public func clear() {
        state.withLock { $0.ring.removeAll() }
    }

    /// Stream of entries appended after subscription. Finishes when the
    /// caller drops the stream.
    public func newEntries() -> AsyncStream<Entry> {
        AsyncStream { continuation in
            let id = UUID()
            state.withLock { $0.continuations[id] = continuation }
            // Weak at the stored closure, not inside a nested one: the
            // continuation holds this handler and the store holds the
            // continuation, so a strong `self` here retains the store for as
            // long as a subscriber keeps the stream (see `MailboxWatcher`).
            continuation.onTermination = { @Sendable [weak self] _ in
                self?.removeContinuation(id: id)
            }
        }
    }

    private func removeContinuation(id: UUID) {
        // The removed continuation is returned so it is released after the
        // lock is, not inside it.
        _ = state.withLock { $0.continuations.removeValue(forKey: id) }
    }

    private struct State {
        var ring: Ring
        var continuations: [UUID: AsyncStream<Entry>.Continuation] = [:]

        init(capacity: Int) {
            ring = Ring(capacity: capacity)
        }
    }

    /// Fixed-capacity ring: once full, each append overwrites the oldest
    /// entry in place instead of shifting the whole buffer.
    private struct Ring {
        let capacity: Int
        private var storage: [Entry] = []
        /// Index of the oldest entry once `storage` is full.
        private var head = 0

        init(capacity: Int) {
            self.capacity = max(capacity, 0)
            storage.reserveCapacity(self.capacity)
        }

        mutating func append(_ entry: Entry) {
            guard capacity > 0 else { return }
            if storage.count < capacity {
                storage.append(entry)
            } else {
                storage[head] = entry
                head = (head + 1) % capacity
            }
        }

        var ordered: [Entry] {
            Array(storage[head...] + storage[..<head])
        }

        mutating func removeAll() {
            storage.removeAll(keepingCapacity: true)
            head = 0
        }
    }
}

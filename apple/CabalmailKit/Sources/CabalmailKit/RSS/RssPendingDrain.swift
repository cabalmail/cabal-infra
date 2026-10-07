import Foundation

/// Pushes `RssStore`'s queue of offline mutations to the server, for
/// `RssSyncEngine.drainPending()`: replayed in the order the user made the
/// changes, item marks coalesced into `/rss_set_item_state` batches, each
/// `/rss_mark_all_read` a fence between batches. A failure leaves the queue
/// intact for the next attempt.
///
/// One pass at a time. A drain asked for before the pass has read the queue
/// joins it; asked for while it is pushing, it waits for one more pass behind
/// it, shared by everyone who asks meanwhile, so a mark made after the queue
/// was read still goes, and a burst of marks costs two passes, not one each.
actor RssPendingDrain {
    let client: RssClient
    let store: RssStore
    /// The pass that has read the queue and is pushing it.
    private var pushing: Flight<Result<Int, Error>>?
    /// The pass waiting to read the queue: joined until it starts.
    private var queued: Flight<Result<Int, Error>>?

    /// Callers waiting on the queued pass: the tests' view of a join.
    var queuedWaiterCount: Int { queued?.run.waiterCount ?? 0 }

    init(client: RssClient, store: RssStore) {
        self.client = client
        self.store = store
    }

    /// Returns how many queue rows were cleared. Throws `CancellationError`
    /// when the caller is cancelled first.
    func drain() async throws -> Int {
        guard !Task.isCancelled else { throw CancellationError() }
        let flight: Flight<Result<Int, Error>>
        let ticket: SharedRun<Result<Int, Error>>.Ticket
        if let queued, let joined = queued.run.join() {
            (flight, ticket) = (queued, joined)
        } else {
            // Behind whichever pass is ahead: the one pushing, or a queued
            // one everybody has left.
            (flight, ticket) = Flight.start(behind: (queued ?? pushing)?.run) { [self] id in
                await begin(id)
                let result: Result<Int, Error>
                do {
                    result = .success(try await pass())
                } catch {
                    result = .failure(error)
                }
                await end(id)
                return result
            }
            queued = flight
        }
        guard let result = await flight.run.value(for: ticket) else { throw CancellationError() }
        return try result.get()
    }

    private func begin(_ id: UUID) {
        guard queued?.id == id else { return }
        pushing = queued
        queued = nil
    }

    private func end(_ id: UUID) {
        if pushing?.id == id { pushing = nil }
    }

    // MARK: - One pass

    /// One server call of a pass, in queue order.
    private enum Step {
        case itemStates([RssItemStateChange], pendingIds: [Int])
        case markAllRead(RssStore.PendingMutation)
    }

    private func pass() async throws -> Int {
        let pending = try await store.pendingMutations()
        guard !pending.isEmpty else { return 0 }
        var cleared = 0
        for step in Self.steps(pending) {
            switch step {
            case .itemStates(let changes, let ids):
                _ = try await client.setItemState(changes)
                try await store.deletePending(ids: ids)
                cleared += ids.count
            case .markAllRead(let mutation):
                // The tap-time watermark, not the replay time: items that
                // arrived while the row sat in the queue stay unread.
                let result = try await client.markAllRead(
                    scope: .subscription(mutation.subscriptionId),
                    watermark: mutation.watermark.isEmpty ? nil : mutation.watermark)
                try await store.applyServerWatermark(subscriptionId: mutation.subscriptionId,
                                                     watermark: result.readWatermark)
                try await store.deletePending(ids: [mutation.id])
                cleared += 1
            }
        }
        return cleared
    }

    /// The queue as server calls. Item marks between two mark-all-reads
    /// coalesce (the queue holds one row per item and kind, so read +
    /// favorite for one item become one change) into batches of at most
    /// 100; a mark-all-read is a fence. The user's order is what the server
    /// must see: replaying "mark all read, then mark X unread" the other
    /// way round lets the server's mark-all-read flip X straight back.
    private static func steps(_ pending: [RssStore.PendingMutation]) -> [Step] {
        var steps: [Step] = []
        var changes: [String: RssItemStateChange] = [:]
        var changeIds: [String: [Int]] = [:]
        func closeBatch() {
            let keys = changes.keys.sorted()
            for start in stride(from: 0, to: keys.count, by: 100) {
                let batch = Array(keys[start..<min(start + 100, keys.count)])
                steps.append(.itemStates(batch.map { changes[$0]! }, pendingIds: batch.flatMap { changeIds[$0] ?? [] }))
            }
            changes = [:]
            changeIds = [:]
        }
        for mutation in pending {
            if mutation.kind == .markAllRead {
                closeBatch()
                steps.append(.markAllRead(mutation))
                continue
            }
            let key = "\(mutation.feedId)#\(mutation.sortKey)"
            var change = changes[key] ?? RssItemStateChange(feedId: mutation.feedId, sortKey: mutation.sortKey)
            if mutation.kind == .read { change.isRead = mutation.value } else { change.isFavorite = mutation.value }
            changes[key] = change
            changeIds[key, default: []].append(mutation.id)
        }
        closeBatch()
        return steps
    }
}

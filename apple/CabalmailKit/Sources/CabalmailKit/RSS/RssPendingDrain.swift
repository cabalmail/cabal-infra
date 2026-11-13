import Foundation

/// Pushes `RssStore`'s queue of offline mutations to the server, for
/// `RssSyncEngine.drainPending()`: replayed in the order the user made the
/// changes, item marks coalesced into `/rss_set_item_state` batches, each
/// `/rss_mark_all_read` a fence between batches. A failure leaves the queue
/// intact for the next attempt, with one exception: a flag add the server
/// refuses because its palette does not hold that flag would be refused
/// every time, and the whole batch with it, so once the app has no
/// settings change waiting to be sent those adds are dropped and the rest
/// of the batch is sent again (`push`).
///
/// One pass at a time. A drain asked for before the pass has read the queue
/// joins it; asked for while it is pushing, it waits for one more pass behind
/// it, shared by everyone who asks meanwhile, so a mark made after the queue
/// was read still goes, and a burst of marks costs two passes, not one each.
actor RssPendingDrain {
    let client: RssClient
    let store: RssStore
    /// Asked before a refused flag add is dropped (`push`).
    let unsentSettings: RssUnsentSettingsHook
    /// The pass that has read the queue and is pushing it.
    private var pushing: Flight<Result<Int, Error>>?
    /// The pass waiting to read the queue: joined until it starts.
    private var queued: Flight<Result<Int, Error>>?

    /// Callers waiting on the queued pass: the tests' view of a join.
    var queuedWaiterCount: Int { queued?.run.waiterCount ?? 0 }

    init(client: RssClient, store: RssStore, unsentSettings: RssUnsentSettingsHook) {
        self.client = client
        self.store = store
        self.unsentSettings = unsentSettings
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
        /// The queue rows of at most 100 items, sent as one change an item.
        case itemStates([RssStore.PendingMutation])
        case markAllRead(RssStore.PendingMutation)
    }

    private func pass() async throws -> Int {
        let pending = try await store.pendingMutations()
        guard !pending.isEmpty else { return 0 }
        var cleared = 0
        for step in Self.steps(pending) {
            switch step {
            case .itemStates(let rows):
                cleared += try await push(rows)
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

    /// Sends one batch and clears its rows from the queue; returns how many
    /// rows left it.
    ///
    /// The server checks every flag a call adds against its copy of the
    /// palette before it writes anything, and refuses the whole call for
    /// one it does not hold. Two things leave such an add in the queue. The
    /// flag was deleted, here or on another device, after the change was
    /// queued, and asking again cannot succeed. Or the flag was created on
    /// this device while the app's settings push was failing, and the
    /// server has not been told of it yet (#2421). So the first refusal of
    /// a batch asks the app to send any settings change still waiting
    /// (`RssUnsentSettingsHook`), and what it answers decides:
    ///   * sent: the batch goes again as it was, and a refusal after that
    ///     is final, since the server's palette is now this device's;
    ///   * still unsent: the refused adds stay queued for a later pass and
    ///     the rest of the batch goes now, because the refusal would
    ///     otherwise hold every other change with it;
    ///   * nothing waiting: the refused adds are taken back
    ///     (`dropRefusedFlagAdds`) and the rest of the batch goes.
    /// Every round after the first takes at least one row out, so this ends.
    private func push(_ rows: [RssStore.PendingMutation]) async throws -> Int {
        var rows = rows
        var cleared = 0
        var asked: RssUnsentSettings?
        while !rows.isEmpty {
            do {
                _ = try await client.setItemState(Self.changes(for: rows))
                break
            } catch let refusal as RssFlagRefusal {
                let refused = rows.filter { $0.kind == .flag && $0.value && refusal.slots.contains($0.slot) }
                // Slots this batch does not add: not something dropping a
                // row here can answer, so the queue stays as any failure
                // leaves it.
                guard !refused.isEmpty else {
                    throw CabalmailError.server(code: RssFlagRefusal.code, message: refusal.message)
                }
                let settings: RssUnsentSettings
                if let asked {
                    settings = asked == .sent ? .nothingUnsent : asked
                } else {
                    settings = await unsentSettings.ask()
                    asked = settings
                }
                let slots = refusal.slots.sorted().joined(separator: ", ")
                switch settings {
                case .sent:
                    CabalmailLog.info("RssPendingDrain", "sent the waiting settings after \(slots) "
                        + "was refused; trying the flag adds again")
                case .stillUnsent:
                    CabalmailLog.warn("RssPendingDrain", "kept \(refused.count) queued flag adds the server "
                        + "refused: \(slots) may be in settings not sent yet")
                    rows.removeAll { refused.contains($0) }
                case .nothingUnsent:
                    // Fewer than `refused` when the user has changed one of
                    // them again since this pass read the queue: that row is
                    // gone and the newer change waits for the next pass.
                    let dropped = try await store.dropRefusedFlagAdds(ids: refused.map(\.id))
                    CabalmailLog.warn("RssPendingDrain", "dropped \(dropped) queued flag adds the server refused: "
                        + "\(slots) not in the palette")
                    rows.removeAll { refused.contains($0) }
                    cleared += dropped
                }
            }
        }
        try await store.deletePending(ids: rows.map(\.id))
        return cleared + rows.count
    }

    /// The queue as server calls. Item marks between two mark-all-reads
    /// coalesce (the queue holds one row per item and kind, and per slot
    /// for a flag change, so every change to one item becomes one entry)
    /// into batches of at most 100 items; a mark-all-read is a fence. The
    /// user's order is what the server must see: replaying "mark all read,
    /// then mark X unread" the other way round lets the server's
    /// mark-all-read flip X straight back.
    private static func steps(_ pending: [RssStore.PendingMutation]) -> [Step] {
        var steps: [Step] = []
        var rows: [String: [RssStore.PendingMutation]] = [:]
        func closeBatch() {
            let keys = rows.keys.sorted()
            for start in stride(from: 0, to: keys.count, by: Self.itemsPerCall) {
                let batch = keys[start..<min(start + Self.itemsPerCall, keys.count)]
                steps.append(.itemStates(batch.flatMap { rows[$0] ?? [] }))
            }
            rows = [:]
        }
        for mutation in pending {
            if mutation.kind == .markAllRead {
                closeBatch()
                steps.append(.markAllRead(mutation))
                continue
            }
            rows["\(mutation.feedId)#\(mutation.sortKey)", default: []].append(mutation)
        }
        closeBatch()
        return steps
    }

    /// The most items `/rss_set_item_state` takes in one call.
    static let itemsPerCall = 100

    /// One entry an item for a batch's rows, in item order: its read and
    /// favorite marks and the flags it adds and removes.
    static func changes(for rows: [RssStore.PendingMutation]) -> [RssItemStateChange] {
        var changes: [String: RssItemStateChange] = [:]
        for row in rows {
            let key = "\(row.feedId)#\(row.sortKey)"
            var change = changes[key] ?? RssItemStateChange(feedId: row.feedId, sortKey: row.sortKey)
            switch row.kind {
            case .read: change.isRead = row.value
            case .favorite: change.isFavorite = row.value
            case .flag:
                // The queue holds one row per item and slot; were there two,
                // the later one is the intent, and a slot never goes in both
                // lists, which the server refuses.
                if row.value {
                    change.removeFlags.remove(row.slot)
                    change.addFlags.insert(row.slot)
                } else {
                    change.addFlags.remove(row.slot)
                    change.removeFlags.insert(row.slot)
                }
            case .markAllRead: continue
            }
            changes[key] = change
        }
        return changes.keys.sorted().compactMap { changes[$0] }
    }
}

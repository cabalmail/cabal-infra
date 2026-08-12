import Foundation

/// Maintains the on-device Core Spotlight index of messages in *subscribed*
/// folders, so system-wide search can surface Cabalmail mail.
///
/// Privacy: everything donated here stays on the device. Core Spotlight's
/// app-donated items are local-only — they are not synced to Apple, other
/// devices, or Spotlight's server-side suggestions — so indexing message
/// metadata and read-body text is privacy-equivalent to the on-disk envelope
/// and body caches the client already keeps.
///
/// Feed paths:
/// - `bind(to:)` consumes the envelope cache's change stream, so every code
///   path that stores or prunes envelopes (list refresh, moves, purges,
///   cross-client expunges) keeps the index current without per-call-site
///   wiring. Upserts are filtered to subscribed folders; deletions always
///   apply (removing a never-indexed item is a no-op).
/// - `sweep(imap:envelopeCache:)` runs once per session start and pulls the
///   top page of envelopes for each subscribed folder, so folders the user
///   doesn't open this session are still searchable. Pages are fed through
///   the envelope cache (warming the offline list for free); the change
///   stream then indexes them.
/// - `indexBody(text:envelope:folder:)` is called when the detail view has
///   parsed a message, adding full-text search for read messages. Bodies are
///   never fetched just to index them.
///
/// Subscription is the user's attention signal (see `FolderListViewModel`):
/// unsubscribed folders never reach Spotlight, and unsubscribing purges the
/// folder's domain from the index.
public actor SpotlightIndexer {
    /// Bumped when already-donated items must be re-donated to be correct —
    /// e.g. the v2 content-type change (`.emailMessage` → `.text`), without
    /// which pre-existing items keep opening Apple Mail on macOS. The sweep
    /// wipes the index once when the persisted marker doesn't match, then
    /// rebuilds it.
    static let schemaVersion = 2
    private static let schemaVersionKey = "cabalmail.spotlight.schemaVersion"

    private let index: SearchableIndexing
    private let defaults: UserDefaults

    /// Nil until the first folder list arrives (`setSubscribedFolders`);
    /// upserts are dropped until then so an unsubscribed folder's envelopes
    /// can never leak into the index during launch races.
    private var subscribedFolders: Set<String>?

    /// Body text donated this session, keyed by `folder\n<uid>` and
    /// re-attached whenever the envelope is re-indexed — a Spotlight upsert
    /// replaces the whole attribute set, so without this a routine flag
    /// refresh would silently strip `textContent` from read messages.
    private var bodyTexts: [String: String] = [:]

    /// Caps for the session-scoped body-text stash and per-donation size.
    /// Eviction is arbitrary-key: the stash only bridges re-indexes within
    /// one session, so precision isn't worth an LRU.
    private let bodyTextCapacity = 512
    private let bodyTextMaxLength = 16_384

    /// Spotlight batch size. `CSSearchableIndex` accepts large arrays, but
    /// bounded chunks keep peak memory flat when a sweep lands thousands of
    /// envelopes at once.
    private let batchSize = 200

    /// Folders swept concurrently. Matches the spirit of
    /// `FolderListViewModel.subscribedRefreshConcurrency`: the Lambda takes
    /// parallel calls happily but there's no throughput to win by stacking
    /// more, and the sweep is background work that shouldn't crowd out
    /// foreground requests.
    private let sweepConcurrency = 2

    /// Envelopes fetched per folder in a sweep — the same order of magnitude
    /// as the list view's first page, so sweep cost stays proportional to
    /// "what the user would see opening the folder".
    private let sweepPageLimit: UInt32 = 200

    public init(index: SearchableIndexing, defaults: UserDefaults = .standard) {
        self.index = index
        self.defaults = defaults
    }

    // MARK: - Envelope-cache feed

    /// Consumes the cache's change stream until the cache is deallocated.
    /// Spawned by `CabalmailClient`'s factory as a background task.
    public func bind(to cache: EnvelopeCache) async {
        let events = await cache.changes()
        for await event in events {
            await handle(event)
        }
    }

    private func handle(_ event: EnvelopeCache.ChangeEvent) async {
        switch event {
        case .upserted(let envelopes, let folder):
            await indexEnvelopes(envelopes, folder: folder)
        case .removed(let uids, let folder):
            await removeMessages(uids: uids, folder: folder)
        case .invalidated(let folder):
            await removeFolder(folder)
        case .cleared:
            await removeAll()
        }
    }

    // MARK: - Subscription state

    /// Replaces the known subscribed set (from a fresh `listFolders`).
    /// Folders that dropped out — unsubscribed or deleted on another
    /// client — get their domains purged.
    public func setSubscribedFolders(_ folders: Set<String>) async {
        let previous = subscribedFolders ?? []
        subscribedFolders = folders
        let dropped = previous.subtracting(folders)
        guard !dropped.isEmpty else { return }
        await purgeDomains(Array(dropped))
    }

    /// Applies a single local subscribe / unsubscribe toggle. Unsubscribing
    /// purges the folder from the index immediately; subscribing just admits
    /// future upserts (the folder indexes on next open or sweep).
    public func noteSubscription(folder: String, isSubscribed: Bool) async {
        if isSubscribed {
            subscribedFolders = (subscribedFolders ?? []).union([folder])
        } else {
            subscribedFolders?.remove(folder)
            await purgeDomains([folder])
        }
    }

    // MARK: - Indexing

    public func indexEnvelopes(_ envelopes: [Envelope], folder: String) async {
        guard index.isAvailable,
              subscribedFolders?.contains(folder) == true,
              !envelopes.isEmpty else { return }
        let entries = envelopes.map { envelope in
            SpotlightEntry(
                envelope: envelope,
                folder: folder,
                textContent: bodyTexts[Self.bodyKey(folder: folder, uid: envelope.uid)]
            )
        }
        var start = 0
        while start < entries.count {
            let end = min(start + batchSize, entries.count)
            do {
                try await index.index(Array(entries[start..<end]))
            } catch {
                CabalmailLog.warn("Spotlight", "index failed for \(folder): \(error)")
                return
            }
            start = end
        }
    }

    /// Adds the parsed plain-text body to the message's index entry. Called
    /// by the detail view after a successful load; same subscription gate as
    /// envelope upserts.
    public func indexBody(text: String, envelope: Envelope, folder: String) async {
        guard index.isAvailable,
              subscribedFolders?.contains(folder) == true else { return }
        let key = Self.bodyKey(folder: folder, uid: envelope.uid)
        if bodyTexts.count >= bodyTextCapacity, bodyTexts[key] == nil,
           let evict = bodyTexts.keys.first {
            bodyTexts.removeValue(forKey: evict)
        }
        let stored = String(text.prefix(bodyTextMaxLength))
        bodyTexts[key] = stored
        let entry = SpotlightEntry(envelope: envelope, folder: folder, textContent: stored)
        do {
            try await index.index([entry])
        } catch {
            CabalmailLog.warn("Spotlight", "body index failed for \(folder): \(error)")
        }
    }

    // MARK: - Removal

    /// Deletions apply regardless of subscription state — deleting an item
    /// that was never indexed is a no-op, and a message moved or expunged
    /// must leave the index even if its folder was unsubscribed in between.
    public func removeMessages(uids: [UInt32], folder: String) async {
        guard !uids.isEmpty else { return }
        for uid in uids {
            bodyTexts.removeValue(forKey: Self.bodyKey(folder: folder, uid: uid))
        }
        let identifiers = uids.map { SpotlightMessageRef(folder: folder, uid: $0).stringValue }
        do {
            try await index.deleteIdentifiers(identifiers)
        } catch {
            CabalmailLog.warn("Spotlight", "delete failed for \(folder): \(error)")
        }
    }

    public func removeFolder(_ folder: String) async {
        await purgeDomains([folder])
    }

    /// Wipes the whole index. Called on sign-out via
    /// `CabalmailClient.clearLocalData()` so the next account on this device
    /// can't surface the previous user's mail from system search.
    public func removeAll() async {
        bodyTexts.removeAll()
        do {
            try await index.deleteAll()
        } catch {
            CabalmailLog.warn("Spotlight", "deleteAll failed: \(error)")
        }
    }

    private func purgeDomains(_ domains: [String]) async {
        let prefixes = domains.map { $0 + "\n" }
        bodyTexts = bodyTexts.filter { key, _ in
            !prefixes.contains { key.hasPrefix($0) }
        }
        do {
            try await index.deleteDomains(domains)
        } catch {
            CabalmailLog.warn("Spotlight", "domain purge failed: \(error)")
        }
    }

    private static func bodyKey(folder: String, uid: UInt32) -> String {
        "\(folder)\n\(uid)"
    }

    // MARK: - Session sweep

    /// One pass over the subscribed folders: refresh the subscription set,
    /// then pull each folder's top page of envelopes through the envelope
    /// cache (whose change stream indexes them, and whose on-disk mirror
    /// doubles as the offline list). Best-effort throughout — a folder that
    /// fails is skipped, and the incremental feed catches it up whenever the
    /// user opens it.
    public func sweep(imap: ImapClient, envelopeCache: EnvelopeCache) async {
        guard index.isAvailable else { return }
        await migrateSchemaIfNeeded()
        guard let folders = try? await imap.listFolders() else {
            CabalmailLog.warn("Spotlight", "sweep skipped: folder list unavailable")
            return
        }
        let subscribed = folders.filter(\.isSubscribed).map(\.path)
        await setSubscribedFolders(Set(subscribed))
        await withTaskGroup(of: Void.self) { group in
            var inFlight = 0
            var next = 0
            while next < subscribed.count || inFlight > 0 {
                while inFlight < sweepConcurrency, next < subscribed.count {
                    let path = subscribed[next]
                    next += 1
                    inFlight += 1
                    group.addTask {
                        await self.sweepFolder(path, imap: imap, envelopeCache: envelopeCache)
                    }
                }
                await group.next()
                inFlight -= 1
            }
        }
        CabalmailLog.info("Spotlight", "sweep finished for \(subscribed.count) folders")
    }

    /// One-time wipe when the entry schema changed (see `schemaVersion`).
    /// The marker is only advanced after a successful wipe, so a failed
    /// deleteAll retries on the next sweep rather than stranding stale
    /// items.
    private func migrateSchemaIfNeeded() async {
        guard defaults.integer(forKey: Self.schemaVersionKey) != Self.schemaVersion else { return }
        do {
            try await index.deleteAll()
        } catch {
            CabalmailLog.warn("Spotlight", "schema-migration wipe failed: \(error)")
            return
        }
        bodyTexts.removeAll()
        defaults.set(Self.schemaVersion, forKey: Self.schemaVersionKey)
        CabalmailLog.info("Spotlight", "index wiped for schema v\(Self.schemaVersion); sweep will rebuild")
    }

    private func sweepFolder(_ path: String, imap: ImapClient, envelopeCache: EnvelopeCache) async {
        guard let status = try? await imap.status(path: path),
              let total = status.messages, total > 0 else { return }
        let limit = min(sweepPageLimit, UInt32(total))
        guard let envelopes = try? await imap.topEnvelopes(
            folder: path,
            limit: limit,
            totalMessages: UInt32(total)
        ) else { return }
        if let uidValidity = status.uidValidity, let uidNext = status.uidNext {
            // Route through the cache: its change stream indexes the page,
            // and the on-disk mirror warms the folder's offline list.
            try? await envelopeCache.merge(
                envelopes: envelopes,
                uidValidity: uidValidity,
                uidNext: uidNext,
                into: path
            )
        } else {
            // No UIDVALIDITY from STATUS — index directly rather than write
            // a cache snapshot with made-up coordinates.
            await indexEnvelopes(envelopes, folder: path)
        }
    }
}

import Foundation

/// The feed items' half of the on-device Spotlight index, beside the
/// messages `SpotlightIndexer` keeps there. It is that indexer's `feeds`,
/// shares its index, and is swept, stopped and wiped with it.
///
/// Items arrive by two paths:
/// - `RssSyncEngine` tells it each page of items it stores and the feeds a
///   catalog refresh removed (`RssItemIndexing`). Those calls only queue;
///   `bind()` works the queue off in order, so a feed sync never waits on
///   Spotlight.
/// - `sweep(_:)` gives each subscribed feed's newest items again at session
///   start, read as text from the feed store. That is what indexes the items
///   already on the device when a build first has this path, and what keeps
///   the top of a feed from expiring, as the folder sweep does for mail.
///
/// A feed's items leave when its subscription does (one domain per feed,
/// `SpotlightFeedItemRef.domainIdentifier`), and everything leaves at
/// sign-out with mail's entries (`SpotlightIndexer.removeAll`). Once
/// `stop()` is called nothing more is indexed, so a sync still in flight
/// when its session ends cannot put an item back after the wipe.
public actor SpotlightFeedIndexer {
    /// What the feed sync wrote, on its way to the index.
    enum Write: Sendable {
        case stored([RssItem])
        case removed([String])
    }

    private let index: SearchableIndexing
    private nonisolated let writes = AsyncStream<Write>.makeStream()
    private var isStopped = false
    private var canIndex: Bool { index.isAvailable && !isStopped }

    /// The same bounds a message's entry has (`SpotlightIndexer`): items per
    /// donation, the text donated for one, and the items given again per
    /// feed at session start, which is the folder sweep's page.
    private let batchSize = 200
    private let maxTextLength = 16_384
    private let sweepLimit = 200

    init(index: SearchableIndexing) {
        self.index = index
    }

    /// Works off what the feed sync wrote, in the order it wrote it, until
    /// the task running this is cancelled. Spawned by `CabalmailClient`'s
    /// factory beside the envelope cache's feed.
    public func bind() async {
        for await write in writes.stream {
            switch write {
            case .stored(let items): await index(items.map(RssItemText.init(item:)))
            case .removed(let feedIDs): await removeFeeds(feedIDs)
            }
        }
    }

    /// Nothing more is indexed. Deletions still apply.
    func stop() {
        isStopped = true
    }

    public func index(_ items: [RssItemText]) async {
        let entries = items.map { SpotlightFeedEntry(text: $0, maxTextLength: maxTextLength) }
        var start = 0
        // Checked before every batch: a stop may come while one is in flight.
        while start < entries.count, canIndex {
            let end = min(start + batchSize, entries.count)
            do {
                try await index.indexFeedItems(Array(entries[start..<end]))
            } catch {
                CabalmailLog.warn("Spotlight", "feed index failed: \(error)")
                return
            }
            start = end
        }
    }

    /// Takes every item of these feeds out of the index: their subscription
    /// left, or a result named an item of a feed this account no longer has.
    public func removeFeeds(_ feedIDs: [String]) async {
        guard !feedIDs.isEmpty else { return }
        do {
            try await index.deleteDomains(feedIDs.map(SpotlightFeedItemRef.domainIdentifier(feedID:)))
        } catch {
            CabalmailLog.warn("Spotlight", "feed purge failed: \(error)")
        }
    }

    /// Takes single items out: results that named an item no longer here.
    public func removeItems(_ refs: [SpotlightFeedItemRef]) async {
        guard !refs.isEmpty else { return }
        do {
            try await index.deleteIdentifiers(refs.map(\.stringValue))
        } catch {
            CabalmailLog.warn("Spotlight", "feed item delete failed: \(error)")
        }
    }

    /// Each subscribed feed's newest items, read as text from `store`.
    func sweep(_ store: RssStore) async {
        guard canIndex, let subscriptions = try? await store.subscriptions() else { return }
        let feedIDs = Set(subscriptions.map(\.feedId)).sorted()
        for feedID in feedIDs {
            let items = try? await store.newestItemText(
                feedId: feedID, limit: sweepLimit, maxTextLength: maxTextLength
            )
            await index(items ?? [])
        }
        CabalmailLog.info("Spotlight", "feed sweep finished for \(feedIDs.count) feeds")
    }
}

extension SpotlightFeedIndexer: RssItemIndexing {
    public nonisolated func itemsStored(_ items: [RssItem]) {
        guard !items.isEmpty else { return }
        writes.continuation.yield(.stored(items))
    }

    public nonisolated func feedsRemoved(_ feedIDs: [String]) {
        guard !feedIDs.isEmpty else { return }
        writes.continuation.yield(.removed(feedIDs))
    }
}

import Foundation
import Synchronization

/// Where an account's caches are on disk: one directory per account under
/// the app's cache root, `accounts/<AccountIdentity.directoryName>/`
/// (`docs/1.x/post-wave-3/sqlite-mail-store.md`, Phase 1).
///
/// Inside it are the saved message lists (`envelopes/`), the message bodies
/// (`bodies/`) and the folder list and counts (`folders/`). The outbox, the
/// drafts, the address list and the feed store stay in the root, shared by
/// whoever is signed in and emptied at sign-out as before; the address list
/// is meant to follow in a later phase.
public enum AccountDirectory {
    /// The directory in the cache root that holds one directory per account.
    public static let containerName = "accounts"

    public static func url(for account: AccountIdentity, in root: URL) -> URL {
        root.appendingPathComponent(containerName, isDirectory: true)
            .appendingPathComponent(account.directoryName, isDirectory: true)
    }

    /// Where the three caches were before they had an account directory.
    /// A client with an account never opens these. Whatever an earlier
    /// build left in them is still the last account's mail, so its wipes
    /// remove them (`CabalmailClient.clearLocalData()`).
    static func legacyCacheDirectories(in root: URL) -> [URL] {
        ["envelopes", "bodies", "folders"].map { root.appendingPathComponent($0, isDirectory: true) }
    }
}

/// The mail caches a client reads and writes and the Spotlight indexer fed
/// from them: the stores every client of one account shares.
struct MailStores: Sendable {
    let envelopeCache: EnvelopeCache
    let bodyCache: MessageBodyCache
    let folderStateCache: FolderStateCache
    let spotlightIndexer: SpotlightIndexer?

    /// Opens the three caches as subdirectories of `directory`.
    /// `searchableIndex` stands in for the device's Spotlight index, which
    /// is what the indexer gets without one where there is Core Spotlight.
    init(directory: URL, bodyCacheCapacityBytes: UInt64, searchableIndex: SearchableIndexing?) throws {
        envelopeCache = try EnvelopeCache(directory: directory.appendingPathComponent("envelopes"))
        bodyCache = try MessageBodyCache(
            directory: directory.appendingPathComponent("bodies"),
            capacityBytes: bodyCacheCapacityBytes
        )
        folderStateCache = FolderStateCache(directory: directory.appendingPathComponent("folders"))
        #if canImport(CoreSpotlight)
        spotlightIndexer = SpotlightIndexer(index: searchableIndex ?? LiveSearchableIndex())
        #else
        spotlightIndexer = searchableIndex.map { SpotlightIndexer(index: $0) }
        #endif
    }

    /// Feeds the indexer from the envelope cache's change stream, and from
    /// what a feed sync tells it, until the task is cancelled. One per
    /// indexer: the feed half reads a queue that has one reader. The task
    /// holds the cache, so the stream does not end on its own while the
    /// process runs. Nil when there is no indexer.
    func startSpotlightFeed() -> Task<Void, Never>? {
        guard let spotlightIndexer else { return nil }
        let cache = envelopeCache
        return Task {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await spotlightIndexer.bind(to: cache) }
                group.addTask { await spotlightIndexer.feeds.bind() }
            }
        }
    }
}

/// Gives every client of one account the same stores.
///
/// Several clients can be alive at once: the wired session's, one parked at
/// a second-factor prompt, and one lent to background work before a session
/// is wired (`SessionManager`). Each used to open caches of its own over
/// one directory. Through here the clients of one account, in one cache
/// root, hold the same cache objects and one Spotlight indexer with one
/// feed, so a change one of them writes is announced to whoever listens
/// through another.
///
/// An account's stores are kept while a client holds a lease on them. A
/// client gives its lease up when it is shut down (or deallocated), and the
/// last one to go takes the Spotlight feed with it; the next client of that
/// account then opens stores afresh. That matters at sign-out, which stops
/// the indexer for good.
///
/// A `Mutex`, not an actor, because `CabalmailClient.make` is synchronous.
/// The directory is made and removed while it is held, so a sign-in that
/// starts as an abandoned one is let go sees one or the other, never half.
final class AccountStoreRegistry: Sendable {
    static let shared = AccountStoreRegistry()

    private struct Entry: Sendable {
        let stores: MailStores
        let directory: URL
        /// The account directory did not exist when these stores opened it.
        let isNew: Bool
        let spotlightFeed: Task<Void, Never>?
        var leases = 0
    }

    private let entries = Mutex<[String: Entry]>([:])

    /// The stores of `account` in the cache root `root`, opened if no
    /// client holds them yet. Opening them creates the account directory.
    func lease(
        root: URL,
        account: AccountIdentity,
        bodyCacheCapacityBytes: UInt64,
        searchableIndex: SearchableIndexing?
    ) throws -> AccountStoreLease {
        let directory = AccountDirectory.url(for: account, in: root)
        let key = directory.standardizedFileURL.path
        let stores = try entries.withLock { entries in
            var entry = try entries[key] ?? Self.open(
                directory, bodyCacheCapacityBytes: bodyCacheCapacityBytes, searchableIndex: searchableIndex
            )
            entry.leases += 1
            entries[key] = entry
            return entry.stores
        }
        return AccountStoreLease(
            stores: stores,
            legacyDirectories: AccountDirectory.legacyCacheDirectories(in: root),
            release: { [weak self] removingNewDirectory in
                self?.release(key: key, removingNewDirectory: removingNewDirectory)
            }
        )
    }

    private static func open(
        _ directory: URL, bodyCacheCapacityBytes: UInt64, searchableIndex: SearchableIndexing?
    ) throws -> Entry {
        let isNew = !FileManager.default.fileExists(atPath: directory.path)
        let stores = try MailStores(
            directory: directory,
            bodyCacheCapacityBytes: bodyCacheCapacityBytes,
            searchableIndex: searchableIndex
        )
        return Entry(stores: stores, directory: directory, isNew: isNew, spotlightFeed: stores.startSpotlightFeed())
    }

    /// One client has let go. The last one ends the Spotlight feed and the
    /// sharing. `removingNewDirectory`: that client was a sign-in that did
    /// not finish, so if these stores made the account directory and nobody
    /// else holds them, the directory goes too. It can only hold what this
    /// run cached, and a later sign-in makes it again.
    private func release(key: String, removingNewDirectory: Bool) {
        entries.withLock { entries in
            guard var entry = entries[key] else { return }
            entry.leases -= 1
            guard entry.leases <= 0 else {
                entries[key] = entry
                return
            }
            entries[key] = nil
            entry.spotlightFeed?.cancel()
            guard removingNewDirectory, entry.isNew else { return }
            if let error = WipeReport.remove(entry.directory, using: .default) {
                CabalmailLog.warn("AccountDirectory", "an unfinished sign-in's directory was not removed: \(error)")
            }
        }
    }
}

/// One client's hold on its account's shared stores
/// (`AccountStoreRegistry`).
final class AccountStoreLease: Sendable {
    let stores: MailStores
    /// Where the caches were before the account directory, for the wipes.
    let legacyDirectories: [URL]

    private let onRelease: @Sendable (_ removingNewDirectory: Bool) -> Void
    private let isReleased = Mutex(false)

    fileprivate init(
        stores: MailStores,
        legacyDirectories: [URL],
        release: @escaping @Sendable (_ removingNewDirectory: Bool) -> Void
    ) {
        self.stores = stores
        self.legacyDirectories = legacyDirectories
        self.onRelease = release
    }

    deinit {
        release()
    }

    /// Gives the hold up; only the first call counts.
    func release(removingNewDirectory: Bool = false) {
        let wasReleased = isReleased.withLock { released in
            defer { released = true }
            return released
        }
        guard !wasReleased else { return }
        onRelease(removingNewDirectory)
    }
}

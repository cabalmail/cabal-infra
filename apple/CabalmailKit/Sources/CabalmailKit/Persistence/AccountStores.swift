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
///
/// A directory lives as long as its account is the one this install
/// remembers. Sign-out removes it, and so does another account's sign-in
/// once it has succeeded, and a launch that remembers another account or
/// none (`AccountDirectoryMaintenance.swift`).
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

    /// What a directory being deleted has in its name. An account's name is
    /// hex, so no account's directory carries it.
    static let beingDeletedMarker = ".deleting-"

    static func isBeingDeleted(_ name: String) -> Bool {
        name.contains(beingDeletedMarker)
    }

    /// A new name beside `directory` for it to be deleted under. Removing a
    /// directory takes a file at a time and can stop half way; a rename is
    /// one step, so the account's name is free of the old mail at once and
    /// whatever a failed removal leaves is found by this name at the next
    /// launch (`prepareAtLaunch(root:remembered:)`).
    static func beingDeletedURL(for directory: URL) -> URL {
        directory.deletingLastPathComponent().appendingPathComponent(
            directory.lastPathComponent + beingDeletedMarker + UUID().uuidString, isDirectory: true
        )
    }
}

/// What a write to a closed store throws: its account signed out, or
/// another one signed in, and its directory is gone.
enum MailStoreError: Error {
    case closed
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

    /// Ends the stores for good, before their directory is removed: nothing
    /// more is indexed, and no cache writes again, so a client still held
    /// cannot put the account's mail back on disk. Returns once no write is
    /// under way.
    func close() async {
        await spotlightIndexer?.stop()
        await envelopeCache.close()
        await bodyCache.close()
        await folderStateCache.close()
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
/// account then opens stores afresh.
///
/// Stores whose directory is removed are retired at once, whoever still
/// holds a lease: at the account's sign-out (`AccountStoreLease
/// .removeAccountDirectory()`) and when another account's sign-in or a
/// launch removes the directory (`removeAccountDirectories(in:except:)`).
/// They are closed first, and the next client of that account opens new
/// ones, so a sign-in straight after a sign-out never gets closed stores.
///
/// A `Mutex`, not an actor, because `CabalmailClient.make` is synchronous.
/// A directory is made, renamed and looked up while it is held, so a
/// sign-in that starts as an abandoned one is let go, or as a sign-out
/// takes the directory, sees one state or the other, never half.
final class AccountStoreRegistry: Sendable {
    static let shared = AccountStoreRegistry()

    private struct Entry: Sendable {
        /// Which opening of the account's stores this is. A lease on stores
        /// that were retired says nothing about the ones opened since.
        let id = UUID()
        let stores: MailStores
        let directory: URL
        /// The account directory did not exist when these stores opened it.
        let isNew: Bool
        let spotlightFeed: Task<Void, Never>?
        var leases = 0
    }

    private let entries = Mutex<[String: Entry]>([:])

    private static func key(_ directory: URL) -> String {
        directory.standardizedFileURL.path
    }

    /// The stores of `account` in the cache root `root`, opened if no
    /// client holds them yet. Opening them creates the account directory.
    func lease(
        root: URL,
        account: AccountIdentity,
        bodyCacheCapacityBytes: UInt64,
        searchableIndex: SearchableIndexing?
    ) throws -> AccountStoreLease {
        let directory = AccountDirectory.url(for: account, in: root)
        let key = Self.key(directory)
        let entry = try entries.withLock { entries in
            var entry = try entries[key] ?? Self.open(
                directory, bodyCacheCapacityBytes: bodyCacheCapacityBytes, searchableIndex: searchableIndex
            )
            entry.leases += 1
            entries[key] = entry
            return entry
        }
        return AccountStoreLease(
            stores: entry.stores, registry: self, root: root, account: account, key: key, entryID: entry.id
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
    /// run cached, and a later sign-in makes it again. Nothing to do when
    /// the stores the lease was on have been retired.
    fileprivate func release(key: String, entryID: UUID, removingNewDirectory: Bool) {
        entries.withLock { entries in
            guard var entry = entries[key], entry.id == entryID else { return }
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

    /// The account signed out: its stores, already closed, are retired and
    /// its directory is renamed for deletion, in one step. Returns what is
    /// left to remove: nil when the directory is already gone, or when the
    /// account's stores have been opened again since the lease's were
    /// retired, and the directory is theirs.
    fileprivate func retire(key: String, entryID: UUID, directory: URL) -> URL? {
        entries.withLock { entries in
            if let entry = entries[key] {
                guard entry.id == entryID else { return nil }
                entries[key] = nil
                entry.spotlightFeed?.cancel()
            }
            return Self.renameForDeletion(directory)
        }
    }

    /// Removes every directory in the root's `accounts/` but `kept`'s: the
    /// other accounts', and whatever a removal that failed left under a
    /// being-deleted name. With no `kept`, all of them. Stores open on one
    /// that goes are closed and retired first.
    ///
    /// Run at launch for the remembered account, and after a sign-in has
    /// succeeded for the account that signed in. Never for a sign-in that
    /// may still be refused: a mistyped username would take the real
    /// account's saved mail.
    func removeAccountDirectories(in root: URL, except kept: AccountIdentity?) async {
        let container = root.appendingPathComponent(AccountDirectory.containerName, isDirectory: true)
        let keptName = kept?.directoryName
        let keptKey = kept.map { Self.key(AccountDirectory.url(for: $0, in: root)) }
        let prefix = Self.key(container) + "/"
        let retired = entries.withLock { entries in
            entries.keys
                .filter { $0.hasPrefix(prefix) && $0 != keptKey }
                .compactMap { entries.removeValue(forKey: $0) }
        }
        for entry in retired {
            entry.spotlightFeed?.cancel()
            await entry.stores.close()
        }
        // A directory with stores open on it now was opened since: a
        // sign-in under way, which removes the others itself if it succeeds.
        let doomed: [URL] = entries.withLock { entries in
            let names = (try? FileManager.default.contentsOfDirectory(atPath: container.path)) ?? []
            return names.filter { $0 != keptName }.compactMap { name -> URL? in
                let directory = container.appendingPathComponent(name, isDirectory: true)
                if AccountDirectory.isBeingDeleted(name) { return directory }
                guard entries[Self.key(directory)] == nil else { return nil }
                return Self.renameForDeletion(directory)
            }
        }
        for directory in doomed {
            Self.remove(directory, named: "saved mail of an account that is not signed in")
        }
    }

    /// Renames `directory` to a being-deleted name. Returns where it is
    /// now: the new name, the old one if the rename failed (it is removed
    /// in place then), or nil if there is no such directory.
    private static func renameForDeletion(_ directory: URL) -> URL? {
        let renamed = AccountDirectory.beingDeletedURL(for: directory)
        do {
            try FileManager.default.moveItem(at: directory, to: renamed)
            return renamed
        } catch CocoaError.fileNoSuchFile, CocoaError.fileReadNoSuchFile {
            return nil
        } catch {
            CabalmailLog.warn("AccountDirectory", "a directory to delete could not be renamed first: \(error)")
            return directory
        }
    }

    /// Removes a directory of saved mail, saying so if any of it is left.
    /// The next launch tries again, if it is under a being-deleted name.
    fileprivate static func remove(_ directory: URL, named name: String) {
        if let error = WipeReport.remove(directory, using: .default) {
            WipeReport.failed(name, error)
        }
    }
}

/// One client's hold on its account's shared stores
/// (`AccountStoreRegistry`).
final class AccountStoreLease: Sendable {
    let stores: MailStores
    /// Where the caches were before the account directory, for the wipes.
    let legacyDirectories: [URL]

    private let registry: AccountStoreRegistry
    private let root: URL
    private let account: AccountIdentity
    /// What the registry knows the stores by, and which opening of them.
    private let key: String
    private let entryID: UUID
    private let isReleased = Mutex(false)

    fileprivate init(
        stores: MailStores,
        registry: AccountStoreRegistry,
        root: URL,
        account: AccountIdentity,
        key: String,
        entryID: UUID
    ) {
        self.stores = stores
        self.legacyDirectories = AccountDirectory.legacyCacheDirectories(in: root)
        self.registry = registry
        self.root = root
        self.account = account
        self.key = key
        self.entryID = entryID
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
        registry.release(key: key, entryID: entryID, removingNewDirectory: removingNewDirectory)
    }

    /// The account's sign-out: closes its stores, for every client that
    /// shares them, and removes its directory. The directory is renamed to
    /// a being-deleted name in one step and removed under that name, so a
    /// removal that fails leaves nothing under the account's name; it is
    /// reported, and the next launch removes what is left. The lease itself
    /// is still given up by `release()`.
    func removeAccountDirectory() async {
        await stores.close()
        let directory = AccountDirectory.url(for: account, in: root)
        guard let doomed = registry.retire(key: key, entryID: entryID, directory: directory) else { return }
        AccountStoreRegistry.remove(doomed, named: "saved message lists, bodies and folder list")
    }

    /// This account has signed in: every other account's directory goes
    /// (`AccountStoreRegistry.removeAccountDirectories(in:except:)`).
    func removeOtherAccountDirectories() async {
        await registry.removeAccountDirectories(in: root, except: account)
    }
}

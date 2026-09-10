import Foundation
import Observation
import CabalmailKit

/// The catalog mutations behind the Feeds management UI (RSS plan, phase
/// 5c): subscribe, unsubscribe, per-subscription settings, folders, OPML.
///
/// Every call goes to the server first and then brings the local store in
/// line, either with the row the server returned (subscribe, update) or by
/// re-reading the catalog (folders, unsubscribe, import), and finally tells
/// the open feed views through `FeedStateBus`. Errors propagate to the
/// presenting sheet, which words them with `FeedErrorText`.
///
/// Takes the Kit pieces directly rather than a `CabalmailClient` so the
/// app-layer tests can drive it with a fake client and a temporary store.
@Observable
@MainActor
final class FeedManagementViewModel {
    private let rss: RssClient
    private let store: RssStore
    private let engine: RssSyncEngine?
    private let bus: FeedStateBus

    /// True while a call is in flight; sheets disable their confirm button.
    var isBusy = false

    init(rss: RssClient, store: RssStore, engine: RssSyncEngine?, bus: FeedStateBus = .shared) {
        self.rss = rss
        self.store = store
        self.engine = engine
        self.bus = bus
    }

    /// Nil when the session has no RSS wiring (a bare client in tests).
    convenience init?(client: CabalmailClient, bus: FeedStateBus = .shared) {
        guard let rss = client.rss, let store = client.rssStore else { return nil }
        self.init(rss: rss, store: store, engine: client.rssSync, bus: bus)
    }

    // MARK: - Subscriptions

    /// Subscribes (or finds the existing subscription for) a feed, stores
    /// it, and pulls its first page so the list has something to show.
    func subscribe(url: String, folderId: String?) async throws -> RssSubscribeResult {
        try await busy {
            let result = try await rss.subscribe(url: url, folderId: folderId.flatMap { $0.isEmpty ? nil : $0 })
            try await store.upsertSubscription(result.subscription)
            bus.postCatalogChanged()
            if !result.existing, let engine {
                // Best effort: the sidebar already shows the feed; items
                // arrive with the next sync if this one fails.
                _ = try? await engine.syncItems(for: result.subscription)
                bus.post()
            }
            return result
        }
    }

    func unsubscribe(_ subscription: RssSubscription) async throws {
        try await busy {
            _ = try await rss.unsubscribe(subscriptionId: subscription.subscriptionId)
            try await refreshCatalog()
        }
    }

    /// Applies a settings change; `update` carries only the changed fields.
    func update(_ subscription: RssSubscription, _ update: RssSubscriptionUpdate) async throws -> RssSubscription {
        try await busy {
            let updated = try await rss.updateSubscription(subscription.subscriptionId, update)
            try await store.upsertSubscription(updated)
            bus.postCatalogChanged()
            return updated
        }
    }

    // MARK: - Folders

    func createFolder(name: String, parentId: String?) async throws -> RssFolder {
        try await busy {
            let folder = try await rss.newFolder(name: name, parentFolderId: parentId.flatMap { $0.isEmpty ? nil : $0 },
                                                 displayOrder: nil)
            try await refreshCatalog()
            return folder
        }
    }

    func updateFolder(_ folder: RssFolder, _ update: RssFolderUpdate) async throws -> RssFolder {
        try await busy {
            let updated = try await rss.updateFolder(folder.folderId, update)
            try await refreshCatalog()
            return updated
        }
    }

    /// Deletes a folder; the server moves its contents to the parent.
    func deleteFolder(_ folder: RssFolder) async throws -> RssFolderDeleteResult {
        try await busy {
            let result = try await rss.deleteFolder(folder.folderId)
            try await refreshCatalog()
            return result
        }
    }

    // MARK: - Read state

    /// Marks every subscription in the scope read: the store first, then a
    /// best-effort push, like the reader's own mutations.
    func markAllRead(scope: RssItemScope) async throws {
        guard let engine else { return }
        let feedIds = Set(try await store.feedIds(in: scope))
        let subs = try await store.subscriptions().filter { feedIds.contains($0.feedId) }
        for sub in subs {
            try await engine.markAllRead(subscriptionId: sub.subscriptionId)
        }
        bus.post()
    }

    // MARK: - OPML

    /// Imports an OPML document; new feeds are fetched server-side, so the
    /// items follow with the sync kicked off here.
    func importOpml(_ opml: String, folderId: String?) async throws -> RssOpmlImportResult {
        try await busy {
            let result = try await rss.importOpml(opml, folderId: folderId)
            try await refreshCatalog()
            if let engine, result.created > 0 {
                Task { [bus] in
                    _ = await engine.syncAll()
                    bus.post()
                }
            }
            return result
        }
    }

    func exportOpml() async throws -> RssOpmlExport {
        try await busy { try await rss.exportOpml() }
    }

    // MARK: - Plumbing

    /// Server catalog → store, dropping departed subscriptions' web storage.
    private func refreshCatalog() async throws {
        let diff: RssStore.CatalogDiff
        if let engine {
            diff = try await engine.refreshCatalog()
        } else {
            diff = try await store.replaceCatalog(try await rss.listSubscriptions())
        }
        FeedWebStorage.drop(uuids: diff.removedDataStoreUuids)
        bus.postCatalogChanged()
    }

    private func busy<T>(_ work: () async throws -> T) async throws -> T {
        isBusy = true
        defer { isBusy = false }
        return try await work()
    }
}

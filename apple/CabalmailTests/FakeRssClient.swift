import Foundation
import CabalmailKit

/// Scripted `RssClient` for the app-layer feed tests: a catalog the tests
/// set, recorded calls, and canned results for the management endpoints.
/// Items calls return empty pages so `RssSyncEngine` can run against it.
actor FakeRssClient: RssClient {
    private(set) var catalog = RssCatalog(folders: [], subscriptions: [])
    private(set) var subscribeCalls: [(url: String, folderId: String?)] = []
    private(set) var unsubscribeCalls: [String] = []
    private(set) var updateCalls: [(id: String, update: RssSubscriptionUpdate)] = []
    private(set) var newFolderCalls: [(name: String, parent: String?)] = []
    private(set) var updateFolderCalls: [(id: String, update: RssFolderUpdate)] = []
    private(set) var deleteFolderCalls: [String] = []
    private(set) var importCalls: [(opml: String, folderId: String?)] = []
    private(set) var markAllReadCalls: [RssItemScope] = []
    private var failNext: Error?

    func set(catalog: RssCatalog) { self.catalog = catalog }
    func set(failNext: Error?) { self.failNext = failNext }

    private func maybeFail() throws {
        if let error = failNext {
            failNext = nil
            throw error
        }
    }

    private func decode<T: Decodable>(_ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    func listSubscriptions() async throws -> RssCatalog { catalog }

    func subscribe(url: String, folderId: String?) async throws -> RssSubscribeResult {
        try maybeFail()
        subscribeCalls.append((url, folderId))
        let sub = RssSubscription(subscriptionId: "sub-\(subscribeCalls.count)", feedId: "feed-\(subscribeCalls.count)",
                                  folderId: folderId ?? "", dataStoreUuid: UUID().uuidString,
                                  feed: RssFeedSummary(feedId: "feed-\(subscribeCalls.count)", canonicalUrl: url,
                                                       title: "Feed \(subscribeCalls.count)"))
        catalog.subscriptions.append(sub)
        return RssSubscribeResult(subscription: sub, existing: false)
    }

    func unsubscribe(subscriptionId: String) async throws -> RssUnsubscribeResult {
        try maybeFail()
        unsubscribeCalls.append(subscriptionId)
        let gone = catalog.subscriptions.first { $0.subscriptionId == subscriptionId }
        catalog.subscriptions.removeAll { $0.subscriptionId == subscriptionId }
        return try decode("""
        {"subscription_id": "\(subscriptionId)", "feed_id": "\(gone?.feedId ?? "")", "feed_purged": true}
        """)
    }

    func updateSubscription(_ subscriptionId: String, _ update: RssSubscriptionUpdate) async throws -> RssSubscription {
        try maybeFail()
        updateCalls.append((subscriptionId, update))
        guard var sub = catalog.subscriptions.first(where: { $0.subscriptionId == subscriptionId }) else {
            throw CabalmailError.server(code: "unknown_subscription", message: "no such subscription")
        }
        if let value = update.customTitle { sub.customTitle = value }
        if let value = update.folderId { sub.folderId = value }
        if let value = update.orderingMode { sub.orderingMode = value }
        if let value = update.defaultOpenMode { sub.defaultOpenMode = value }
        if let value = update.defaultStyling { sub.defaultStyling = value }
        if let value = update.defaultRemoteContent { sub.defaultRemoteContent = value }
        catalog.subscriptions = catalog.subscriptions.map { $0.subscriptionId == subscriptionId ? sub : $0 }
        return sub
    }

    func newFolder(name: String, parentFolderId: String?, displayOrder: Int?) async throws -> RssFolder {
        try maybeFail()
        newFolderCalls.append((name, parentFolderId))
        let folder = RssFolder(folderId: "folder-\(newFolderCalls.count)", parentFolderId: parentFolderId ?? "",
                               name: name)
        catalog.folders.append(folder)
        return folder
    }

    func updateFolder(_ folderId: String, _ update: RssFolderUpdate) async throws -> RssFolder {
        try maybeFail()
        updateFolderCalls.append((folderId, update))
        guard var folder = catalog.folders.first(where: { $0.folderId == folderId }) else {
            throw CabalmailError.server(code: "unknown_folder", message: "no such folder")
        }
        if let value = update.name { folder.name = value }
        if let value = update.parentFolderId { folder.parentFolderId = value }
        catalog.folders = catalog.folders.map { $0.folderId == folderId ? folder : $0 }
        return folder
    }

    func deleteFolder(_ folderId: String) async throws -> RssFolderDeleteResult {
        try maybeFail()
        deleteFolderCalls.append(folderId)
        let parent = catalog.folders.first { $0.folderId == folderId }?.parentFolderId ?? ""
        catalog.folders.removeAll { $0.folderId == folderId }
        catalog.subscriptions = catalog.subscriptions.map {
            var sub = $0
            if sub.folderId == folderId { sub.folderId = parent }
            return sub
        }
        return try decode("""
        {"folder_id": "\(folderId)", "moved_subscriptions": 0, "moved_folders": 0, "parent_folder_id": "\(parent)"}
        """)
    }

    func listItems(scope: RssItemScope, filter: RssItemFilter, order: RssItemOrder, limit: Int,
                   cursor: String?) async throws -> RssItemsPage {
        RssItemsPage(items: [], nextCursor: nil)
    }

    func syncItems(subscriptionId: String, since: String, limit: Int) async throws -> RssSyncPage {
        RssSyncPage(items: [], nextSince: since, hasMore: false)
    }

    func syncItemStates(subscriptionId: String, since: String, limit: Int) async throws -> RssStateSyncPage {
        RssStateSyncPage(states: [], nextSince: since, hasMore: false)
    }

    func getItem(feedId: String, sortKey: String) async throws -> RssItem {
        throw CabalmailError.server(code: "not_found", message: "unused")
    }

    func setItemState(_ changes: [RssItemStateChange]) async throws -> Int { changes.count }

    func markAllRead(scope: RssItemScope) async throws -> RssMarkAllReadResult {
        markAllReadCalls.append(scope)
        return try decode(#"{"subscriptions": 1, "flipped": 0, "read_watermark": "2026-09-10T00:00:00+00:00"}"#)
    }

    func importOpml(_ opml: String, folderId: String?) async throws -> RssOpmlImportResult {
        try maybeFail()
        importCalls.append((opml, folderId))
        return try decode(#"{"created": 2, "existing": 1, "folders_created": 1, "failed": []}"#)
    }

    func exportOpml() async throws -> RssOpmlExport {
        try maybeFail()
        return try decode(#"{"opml": "<opml version=\"2.0\"/>", "filename": "feeds.opml"}"#)
    }
}

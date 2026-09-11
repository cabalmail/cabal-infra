import Foundation

// MARK: - RSS reader endpoints (docs/rss.md)

/// The RSS endpoints' error body: `{"Error": message, "code": token}`.
private struct RssErrorEnvelope: Decodable {
    let code: String?
    let error: String?
    private enum CodingKeys: String, CodingKey { case code, error = "Error" }
}

extension URLSessionApiClient: RssClient {
    public func listSubscriptions() async throws -> RssCatalog {
        let request = try await get("/rss_list_subscriptions")
        return try await decodeRss(RssCatalog.self, from: request)
    }

    public func subscribe(url: String, folderId: String?) async throws -> RssSubscribeResult {
        var body: [String: Any] = ["url": url]
        if let folderId, !folderId.isEmpty { body["folder_id"] = folderId }
        let request = try await post("/rss_subscribe", json: body)
        return try await decodeRss(RssSubscribeResult.self, from: request)
    }

    public func unsubscribe(subscriptionId: String) async throws -> RssUnsubscribeResult {
        let request = try await post("/rss_unsubscribe", json: ["subscription_id": subscriptionId])
        return try await decodeRss(RssUnsubscribeResult.self, from: request)
    }

    public func updateSubscription(
        _ subscriptionId: String, _ update: RssSubscriptionUpdate
    ) async throws -> RssSubscription {
        var body: [String: Any] = ["subscription_id": subscriptionId]
        if let value = update.customTitle { body["custom_title"] = value }
        if let value = update.folderId { body["folder_id"] = value }
        if let value = update.orderingMode { body["ordering_mode"] = value.rawValue }
        if let value = update.defaultOpenMode { body["default_open_mode"] = value.rawValue }
        if let value = update.defaultStyling { body["default_styling"] = value.rawValue }
        if let value = update.defaultRemoteContent { body["default_remote_content"] = value.rawValue }
        if let value = update.notificationsEnabled { body["notifications_enabled"] = value }
        let request = try await put("/rss_update_subscription", json: body)
        struct Payload: Decodable { let subscription: RssSubscription }
        return try await decodeRss(Payload.self, from: request).subscription
    }

    public func newFolder(name: String, parentFolderId: String?, displayOrder: Int?) async throws -> RssFolder {
        var body: [String: Any] = ["name": name]
        if let parentFolderId, !parentFolderId.isEmpty { body["parent_folder_id"] = parentFolderId }
        if let displayOrder { body["display_order"] = displayOrder }
        let request = try await post("/rss_new_folder", json: body)
        struct Payload: Decodable { let folder: RssFolder }
        return try await decodeRss(Payload.self, from: request).folder
    }

    public func updateFolder(_ folderId: String, _ update: RssFolderUpdate) async throws -> RssFolder {
        var body: [String: Any] = ["folder_id": folderId]
        if let value = update.name { body["name"] = value }
        if let value = update.parentFolderId { body["parent_folder_id"] = value }
        if let value = update.displayOrder { body["display_order"] = value }
        let request = try await put("/rss_update_folder", json: body)
        struct Payload: Decodable { let folder: RssFolder }
        return try await decodeRss(Payload.self, from: request).folder
    }

    public func deleteFolder(_ folderId: String) async throws -> RssFolderDeleteResult {
        let request = try await post("/rss_delete_folder", json: ["folder_id": folderId])
        return try await decodeRss(RssFolderDeleteResult.self, from: request)
    }

    public func listItems(
        scope: RssItemScope, filter: RssItemFilter, order: RssItemOrder, limit: Int, cursor: String?
    ) async throws -> RssItemsPage {
        var query = scopeQuery(scope) + [
            URLQueryItem(name: "filter", value: filter.rawValue),
            URLQueryItem(name: "order", value: order.rawValue),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        if let cursor, !cursor.isEmpty { query.append(URLQueryItem(name: "cursor", value: cursor)) }
        let request = try await get("/rss_list_items", query: query)
        return try await decodeRss(RssItemsPage.self, from: request)
    }

    public func syncItems(subscriptionId: String, since: String, limit: Int) async throws -> RssSyncPage {
        let request = try await get("/rss_list_items", query: [
            URLQueryItem(name: "subscription_id", value: subscriptionId),
            URLQueryItem(name: "since", value: since),
            URLQueryItem(name: "limit", value: String(limit)),
        ])
        return try await decodeRss(RssSyncPage.self, from: request)
    }

    public func syncItemStates(subscriptionId: String, since: String, limit: Int) async throws -> RssStateSyncPage {
        let request = try await get("/rss_list_items", query: [
            URLQueryItem(name: "subscription_id", value: subscriptionId),
            URLQueryItem(name: "state_since", value: since),
            URLQueryItem(name: "limit", value: String(limit)),
        ])
        return try await decodeRss(RssStateSyncPage.self, from: request)
    }

    public func getItem(feedId: String, sortKey: String) async throws -> RssItem {
        let request = try await get("/rss_get_item", query: [
            URLQueryItem(name: "feed_id", value: feedId),
            URLQueryItem(name: "sort_key", value: sortKey),
        ])
        struct Payload: Decodable { let item: RssItem }
        return try await decodeRss(Payload.self, from: request).item
    }

    public func setItemState(_ changes: [RssItemStateChange]) async throws -> Int {
        let entries: [[String: Any]] = changes.map { change in
            var entry: [String: Any] = ["feed_id": change.feedId, "sort_key": change.sortKey]
            if let isRead = change.isRead { entry["is_read"] = isRead }
            if let isFavorite = change.isFavorite { entry["is_favorite"] = isFavorite }
            return entry
        }
        let request = try await post("/rss_set_item_state", json: ["items": entries])
        struct Payload: Decodable { let updated: Int }
        return try await decodeRss(Payload.self, from: request).updated
    }

    public func markAllRead(scope: RssItemScope) async throws -> RssMarkAllReadResult {
        var body: [String: Any] = [:]
        switch scope {
        case .subscription(let id): body["subscription_id"] = id
        case .folder(let id): body["folder_id"] = id
        case .all: break
        }
        let request = try await post("/rss_mark_all_read", json: body)
        return try await decodeRss(RssMarkAllReadResult.self, from: request)
    }

    public func importOpml(_ opml: String, folderId: String?) async throws -> RssOpmlImportResult {
        var body: [String: Any] = ["opml": opml]
        if let folderId, !folderId.isEmpty { body["folder_id"] = folderId }
        let request = try await post("/rss_opml_import", json: body)
        return try await decodeRss(RssOpmlImportResult.self, from: request)
    }

    public func exportOpml() async throws -> RssOpmlExport {
        let request = try await get("/rss_opml_export")
        return try await decodeRss(RssOpmlExport.self, from: request)
    }

    // MARK: - Plumbing

    private func scopeQuery(_ scope: RssItemScope) -> [URLQueryItem] {
        switch scope {
        case .subscription(let id): return [URLQueryItem(name: "subscription_id", value: id)]
        case .folder(let id): return [URLQueryItem(name: "folder_id", value: id)]
        case .all: return []
        }
    }

    /// `send` + decode, with the RSS error envelope's `code` token promoted
    /// into `CabalmailError.server(code:)` so callers can branch on
    /// `not_a_feed`, `needs_credentials`, and friends instead of on status.
    private func decodeRss<T: Decodable>(_ type: T.Type, from request: URLRequest) async throws -> T {
        let data: Data
        do {
            data = try await send(request, expectedStatuses: 200..<300)
        } catch let CabalmailError.server(status, message) {
            if let envelope = try? JSONDecoder().decode(RssErrorEnvelope.self, from: Data(message.utf8)),
               let code = envelope.code, !code.isEmpty {
                throw CabalmailError.server(code: code, message: envelope.error ?? message)
            }
            throw CabalmailError.server(code: status, message: message)
        }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw CabalmailError.server(code: "decode", message: "Unexpected RSS response: \(error)")
        }
    }
}

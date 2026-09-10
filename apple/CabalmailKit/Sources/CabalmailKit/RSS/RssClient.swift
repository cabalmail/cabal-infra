import Foundation

/// The RSS reader's server surface (`docs/rss.md`), one method per endpoint.
///
/// Unlike mail there is no direct-protocol alternative to keep alive: the
/// only production implementation is `URLSessionApiClient` (see
/// `URLSessionApiClient+Rss.swift`). The protocol exists so `RssSyncEngine`
/// and the view models can be exercised against a fake.
///
/// Server-side failures with a documented `code` token surface as
/// `CabalmailError.server(code: <token>, message: <Error>)`, e.g.
/// `code == "not_a_feed"`; failures without one carry the HTTP status.
public protocol RssClient: Sendable {
    func listSubscriptions() async throws -> RssCatalog
    func subscribe(url: String, folderId: String?) async throws -> RssSubscribeResult
    func unsubscribe(subscriptionId: String) async throws -> RssUnsubscribeResult
    func updateSubscription(_ subscriptionId: String, _ update: RssSubscriptionUpdate) async throws -> RssSubscription
    func newFolder(name: String, parentFolderId: String?, displayOrder: Int?) async throws -> RssFolder
    func updateFolder(_ folderId: String, _ update: RssFolderUpdate) async throws -> RssFolder
    func deleteFolder(_ folderId: String) async throws -> RssFolderDeleteResult
    /// The merged listing: one page ordered by sort key across the scope.
    func listItems(
        scope: RssItemScope, filter: RssItemFilter, order: RssItemOrder, limit: Int, cursor: String?
    ) async throws -> RssItemsPage
    /// The since-sync form: items ingested after `since` (a `fetchedKey`),
    /// oldest-ingested first. `since` "" starts from the beginning.
    func syncItems(subscriptionId: String, since: String, limit: Int) async throws -> RssSyncPage
    func getItem(feedId: String, sortKey: String) async throws -> RssItem
    /// Returns the number of state rows written (at most 100 per call).
    func setItemState(_ changes: [RssItemStateChange]) async throws -> Int
    func markAllRead(scope: RssItemScope) async throws -> RssMarkAllReadResult
    func importOpml(_ opml: String, folderId: String?) async throws -> RssOpmlImportResult
    func exportOpml() async throws -> RssOpmlExport
}

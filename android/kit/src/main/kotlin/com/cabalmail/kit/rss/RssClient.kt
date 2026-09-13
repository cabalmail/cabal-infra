package com.cabalmail.kit.rss

import com.cabalmail.kit.models.RssCatalog
import com.cabalmail.kit.models.RssFolder
import com.cabalmail.kit.models.RssFolderDeleteResult
import com.cabalmail.kit.models.RssFolderUpdate
import com.cabalmail.kit.models.RssItem
import com.cabalmail.kit.models.RssItemFilter
import com.cabalmail.kit.models.RssItemOrder
import com.cabalmail.kit.models.RssItemScope
import com.cabalmail.kit.models.RssItemStateChange
import com.cabalmail.kit.models.RssItemsPage
import com.cabalmail.kit.models.RssMarkAllReadResult
import com.cabalmail.kit.models.RssOpmlExport
import com.cabalmail.kit.models.RssOpmlImportResult
import com.cabalmail.kit.models.RssStateSyncPage
import com.cabalmail.kit.models.RssSubscribeResult
import com.cabalmail.kit.models.RssSubscription
import com.cabalmail.kit.models.RssSubscriptionUpdate
import com.cabalmail.kit.models.RssSyncPage
import com.cabalmail.kit.models.RssUnsubscribeResult

/**
 * The RSS half of the Lambda API (`docs/rss.md`), the Kotlin sibling of
 * the Apple kit's `RssClient`. `ApiClient` is the only production
 * implementation; the interface exists so [RssSyncEngine] can be driven by
 * a scripted fake in tests, the way the Apple engine is.
 *
 * `/rss_list_items` has three forms, kept as three methods: [listItems]
 * (a merged listing with an opaque page cursor), [syncItems] (items
 * ingested since a `fetched_key`, oldest-ingested first) and
 * [syncItemStates] (the caller's read/favorite rows changed since an
 * opaque state cursor). A client cache needs the last two together: ingest
 * time does not move when state does, so the item sync alone never
 * re-delivers a mark made on another device.
 */
interface RssClient {
    suspend fun listSubscriptions(): RssCatalog

    suspend fun subscribe(
        url: String,
        folderId: String? = null,
    ): RssSubscribeResult

    suspend fun unsubscribe(subscriptionId: String): RssUnsubscribeResult

    suspend fun updateSubscription(
        subscriptionId: String,
        update: RssSubscriptionUpdate,
    ): RssSubscription

    suspend fun newRssFolder(
        name: String,
        parentFolderId: String? = null,
        displayOrder: Int? = null,
    ): RssFolder

    suspend fun updateRssFolder(
        folderId: String,
        update: RssFolderUpdate,
    ): RssFolder

    suspend fun deleteRssFolder(folderId: String): RssFolderDeleteResult

    suspend fun listItems(
        scope: RssItemScope,
        filter: RssItemFilter = RssItemFilter.ALL,
        order: RssItemOrder = RssItemOrder.NEWEST,
        limit: Int = 50,
        cursor: String? = null,
    ): RssItemsPage

    suspend fun syncItems(
        subscriptionId: String,
        since: String,
        limit: Int = 100,
    ): RssSyncPage

    suspend fun syncItemStates(
        subscriptionId: String,
        since: String,
        limit: Int = 100,
    ): RssStateSyncPage

    suspend fun getItem(
        feedId: String,
        sortKey: String,
    ): RssItem

    /** At most 100 changes per call; returns the server's `updated` count. */
    suspend fun setItemState(changes: List<RssItemStateChange>): Int

    suspend fun markAllRead(scope: RssItemScope): RssMarkAllReadResult

    suspend fun importOpml(
        opml: String,
        folderId: String? = null,
    ): RssOpmlImportResult

    suspend fun exportOpml(): RssOpmlExport
}

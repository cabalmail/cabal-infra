package com.cabalmail.android.ui.feeds

import com.cabalmail.kit.models.RssItem
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.asSharedFlow

/**
 * Cross-screen feed changes, the Android sibling of the Apple `FeedStateBus`:
 * an item's read or favorite flag changed (lists patch the row in place, the
 * feed list re-reads its counts), something broad changed (a sync, a
 * mark-all-read: first-page lists reload, the feed list reloads), or the
 * catalog itself changed (folders or subscriptions came or went).
 */
sealed interface FeedEvent {
    data class ItemChanged(
        val item: RssItem,
    ) : FeedEvent

    data object Changed : FeedEvent

    data object CatalogChanged : FeedEvent
}

class FeedEventBus {
    private val mutable = MutableSharedFlow<FeedEvent>(extraBufferCapacity = 16)
    val events: SharedFlow<FeedEvent> = mutable.asSharedFlow()

    fun post(event: FeedEvent) {
        mutable.tryEmit(event)
    }
}

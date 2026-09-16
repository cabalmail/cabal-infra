package com.cabalmail.android.ui.feeds

import android.net.Uri
import com.cabalmail.kit.models.RssItem
import com.cabalmail.kit.models.RssItemScope

/**
 * The feed routes. Scopes travel as their `RssItemScope.token` and items
 * as `feed_id` + `sort_key`, the same identities the Apple session record
 * stores, so the resume-session plan's Phase B can name a position here
 * and Phase C can hand one between platforms without translation. Both
 * are URL-encoded on the way in (a sort key carries `#`, `+` and `:`).
 */
object FeedRoutes {
    const val HUB = "feeds"
    const val ITEMS = "feeds/items/{scope}?item={item}"
    const val ITEM = "feeds/item/{feedId}/{sortKey}"

    /** Every route that belongs to the Feeds tab. */
    val ALL = setOf(HUB, ITEMS, ITEM)

    fun items(
        scope: RssItemScope,
        item: RssItem? = null,
        encode: (String) -> String = Uri::encode,
    ): String {
        val base = "feeds/items/${encode(scope.token)}"
        return if (item == null) base else "$base?item=${encode(item.id)}"
    }

    fun item(
        feedId: String,
        sortKey: String,
        encode: (String) -> String = Uri::encode,
    ): String = "feeds/item/${encode(feedId)}/${encode(sortKey)}"

    /** `feedId#sortKey` (an item's `id`) split back into its parts; null for junk. */
    fun splitItemId(id: String): Pair<String, String>? {
        val separator = id.indexOf('#')
        if (separator <= 0 || separator == id.length - 1) return null
        return id.substring(0, separator) to id.substring(separator + 1)
    }
}

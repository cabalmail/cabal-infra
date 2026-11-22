package com.cabalmail.kit.models

/**
 * One identity for a message or a feed item, so a list that holds both
 * (the Flagged view) can key, compare and open its rows without asking
 * which medium each is. The Kotlin sibling of the Apple kit's `ItemRef`
 * (`docs/1.x/post-wave-3/flags-and-cross-media.md`, B5.1).
 *
 * A message is its folder and UID; a feed item is its feed and sort key,
 * the pair the feed routes and the resume record already use. Nothing
 * stored or sent embeds a ref: it lives as long as the list that made it.
 */
sealed interface ItemRef {
    /** Unique across both media, and stable for as long as the item is where it was. */
    val key: String

    data class Mail(
        val folder: String,
        val uid: Long,
    ) : ItemRef {
        override val key: String get() = "mail:$folder/$uid"
    }

    data class Feed(
        val feedId: String,
        val sortKey: String,
    ) : ItemRef {
        override val key: String get() = "feed:$feedId#$sortKey"
    }
}

/**
 * The message's ref, or null when nothing says which folder it is in: an
 * envelope names its folder only when it came from a search, so a caller
 * that knows the folder passes it.
 */
fun Envelope.ref(folder: String? = this.folder): ItemRef.Mail? = folder?.let { ItemRef.Mail(it, id) }

val RssItem.ref: ItemRef.Feed
    get() = ItemRef.Feed(feedId, sortKey)

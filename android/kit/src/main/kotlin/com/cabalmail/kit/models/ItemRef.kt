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

    companion object {
        private const val MAIL = "mail:"
        private const val FEED = "feed:"

        /**
         * The ref a [key] was made from, or null for anything else. A
         * folder path may hold `/`, so a message's UID is what follows the
         * last one; a feed id holds no `#`, and a sort key may, so a feed
         * item's parts divide at the first.
         */
        fun parse(key: String): ItemRef? =
            when {
                key.startsWith(MAIL) -> {
                    val rest = key.removePrefix(MAIL)
                    val folder = rest.substringBeforeLast('/', "")
                    val uid = rest.substringAfterLast('/', "").toLongOrNull()
                    if (folder.isEmpty() || uid == null) null else Mail(folder, uid)
                }
                key.startsWith(FEED) -> {
                    val rest = key.removePrefix(FEED)
                    val feedId = rest.substringBefore('#', "")
                    val sortKey = rest.substringAfter('#', "")
                    if (feedId.isEmpty() || sortKey.isEmpty()) null else Feed(feedId, sortKey)
                }
                else -> null
            }
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

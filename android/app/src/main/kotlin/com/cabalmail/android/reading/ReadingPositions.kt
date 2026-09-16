package com.cabalmail.android.reading

import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import java.io.File

/**
 * Keys for [ReadingPositions], one scheme per item kind so a mail message
 * and a feed item can never collide — the same scheme as the Apple
 * client's `ReadingPositionKey`.
 */
object ReadingPositionKey {
    /**
     * Message-ID when known — it survives a move between folders — else the
     * folder + UID the reader was opened with.
     */
    fun mail(
        messageId: String?,
        folder: String,
        uid: Long,
    ): String = if (!messageId.isNullOrEmpty()) "mail:$messageId" else "mail:$folder#$uid"

    /** `RssItem.id` (`feedId#sortKey`), stable across feeds. */
    fun feed(itemId: String): String = "feed:$itemId"
}

/**
 * Where the reader left off in each item, per install — the Android half
 * of the resume-session plan's reading-position cache, for mail messages
 * and feed items alike. Keyed by [ReadingPositionKey], bounded to the most
 * recent [capacity] entries, persisted as one JSON file.
 *
 * The anchor is the Apple client's `f<fraction>` form: the scroll offset
 * as a fraction of the scrollable height. Android's body `WebView` runs
 * with JavaScript off, so the element anchor (`i<path>|<delta>`) the Apple
 * reader captures through its DOM script is not available here (resume
 * plan, Phase D); the fraction is what the `WebView` reports natively, and
 * it is the form the Apple reader falls back to and restores from. A
 * position at the top is not stored; an existing entry is cleared.
 *
 * Reads an older feed-only file (`feed-positions.json`, keyed by bare
 * `RssItem.id`) once when this one does not exist yet, so positions
 * recorded before the mail half existed carry over.
 */
class ReadingPositions(
    private val file: File,
    private val legacyFeedFile: File? = null,
    private val capacity: Int = 200,
    private val io: CoroutineDispatcher = Dispatchers.IO,
) {
    private val mutex = Mutex()
    private var loaded: LinkedHashMap<String, String>? = null
    private val json = Json

    suspend fun anchor(key: String): String? = mutex.withLock { entries()[key] }

    /** The stored fraction for [key], or null. */
    suspend fun fraction(key: String): Float? = anchor(key)?.let(ReadingAnchor::fraction)

    suspend fun record(
        key: String,
        fraction: Float,
    ) = mutex.withLock {
        val map = entries()
        val anchor = ReadingAnchor.format(fraction)
        if (anchor == null) {
            if (map.remove(key) != null) persist(map)
            return@withLock
        }
        if (map[key] == anchor) return@withLock
        map.remove(key)
        map[key] = anchor
        while (map.size > capacity) map.remove(map.keys.first())
        persist(map)
    }

    /** Sign-out: forget every position. */
    suspend fun clear() =
        mutex.withLock {
            loaded = LinkedHashMap()
            withContext(io) {
                file.delete()
                legacyFeedFile?.delete()
            }
        }

    private suspend fun entries(): LinkedHashMap<String, String> =
        loaded ?: withContext(io) {
            val read =
                runCatching { json.decodeFromString<Map<String, String>>(file.readText()) }.getOrNull()
            if (read != null) {
                LinkedHashMap(read)
            } else {
                // First run after the mail half arrived: adopt the feed-only file.
                val legacy =
                    legacyFeedFile
                        ?.let { old ->
                            runCatching { json.decodeFromString<Map<String, String>>(old.readText()) }.getOrNull()
                        }.orEmpty()
                LinkedHashMap(legacy.mapKeys { (id, _) -> ReadingPositionKey.feed(id) })
            }
        }.also { loaded = it }

    private suspend fun persist(map: Map<String, String>) =
        withContext(io) {
            runCatching {
                file.parentFile?.mkdirs()
                val tmp = File(file.parentFile, file.name + ".tmp")
                tmp.writeText(json.encodeToString(map))
                tmp.renameTo(file)
                legacyFeedFile?.delete()
            }
        }
}

/** The `f<fraction>` anchor codec, shared with the Apple reader's fallback form. */
object ReadingAnchor {
    /** Null at the top (nothing worth restoring); otherwise `f0.420`-style, three decimals. */
    fun format(fraction: Float): String? {
        val clamped = fraction.coerceIn(0f, 1f)
        if (clamped < 0.01f) return null
        return "f" + String.format(java.util.Locale.ROOT, "%.3f", clamped)
    }

    fun fraction(anchor: String): Float? {
        if (!anchor.startsWith("f")) return null
        return anchor.drop(1).toFloatOrNull()?.takeIf { it in 0f..1f }
    }
}

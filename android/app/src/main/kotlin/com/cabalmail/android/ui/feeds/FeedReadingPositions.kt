package com.cabalmail.android.ui.feeds

import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import java.io.File

/**
 * Where the reader left off in each feed item, per install (the feed half
 * of the resume-session plan's reading-position cache). Keyed by the
 * item's `feedId#sortKey`, bounded to the most recent [capacity]
 * entries, persisted as one JSON file.
 *
 * The anchor is the Apple client's `f<fraction>` form: the scroll offset
 * as a fraction of the scrollable height. Android's body view runs with
 * JavaScript off, so the element anchor (`i<path>|<delta>`) the Apple
 * reader captures through its DOM script is not available here; the
 * fraction is what the WebView reports natively, and it is the form the
 * Apple reader falls back to and restores from, so a position captured
 * here restores there once the cross-device hand-off carries it. A
 * position at the top is not stored; an existing entry is cleared.
 */
class FeedReadingPositions(
    private val file: File,
    private val capacity: Int = 200,
    private val io: CoroutineDispatcher = Dispatchers.IO,
) {
    private val mutex = Mutex()
    private var loaded: LinkedHashMap<String, String>? = null
    private val json = Json

    suspend fun anchor(itemId: String): String? = mutex.withLock { entries()[itemId] }

    /** The stored fraction for an item, or null. */
    suspend fun fraction(itemId: String): Float? = anchor(itemId)?.let(FeedReadingAnchor::fraction)

    suspend fun record(
        itemId: String,
        fraction: Float,
    ) = mutex.withLock {
        val map = entries()
        map.remove(itemId)
        val anchor = FeedReadingAnchor.format(fraction)
        if (anchor != null) {
            map[itemId] = anchor
            while (map.size > capacity) map.remove(map.keys.first())
        }
        persist(map)
    }

    private suspend fun entries(): LinkedHashMap<String, String> =
        loaded ?: withContext(io) {
            val read =
                runCatching { json.decodeFromString<Map<String, String>>(file.readText()) }.getOrNull().orEmpty()
            LinkedHashMap(read)
        }.also { loaded = it }

    private suspend fun persist(map: Map<String, String>) =
        withContext(io) {
            file.parentFile?.mkdirs()
            val tmp = File(file.parentFile, file.name + ".tmp")
            tmp.writeText(json.encodeToString(map))
            tmp.renameTo(file)
        }
}

/** The `f<fraction>` anchor codec, shared with the Apple reader's fallback form. */
object FeedReadingAnchor {
    /** Null at the top (nothing worth restoring); otherwise `f0.42`-style, three decimals. */
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

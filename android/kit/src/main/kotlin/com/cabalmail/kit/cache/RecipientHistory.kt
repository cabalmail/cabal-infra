package com.cabalmail.kit.cache

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import java.io.File

/**
 * Learned recipient list backing compose autocomplete (plan §5.1): every
 * address the user has sent to, ranked by use count then recency, capped
 * so the file stays small. Local to the install; no server round trip.
 */
class RecipientHistory(
    private val file: File,
    private val maxEntries: Int = DEFAULT_MAX_ENTRIES,
    private val clock: () -> Long = System::currentTimeMillis,
) {
    @Serializable
    data class Entry(
        val address: String,
        val count: Int,
        val lastUsed: Long,
    )

    private val json = Json { ignoreUnknownKeys = true }
    private val mutex = Mutex()
    private var cache: MutableMap<String, Entry>? = null

    /** Records one use of each address (case-insensitive key). */
    suspend fun record(addresses: Collection<String>) {
        if (addresses.isEmpty()) {
            return
        }
        mutex.withLock {
            val entries = loadLocked()
            val now = clock()
            addresses.map { it.trim() }.filter { it.contains('@') }.forEach { address ->
                val key = address.lowercase()
                val prior = entries[key]
                entries[key] = Entry(address = address, count = (prior?.count ?: 0) + 1, lastUsed = now)
            }
            if (entries.size > maxEntries) {
                entries.values
                    .sortedWith(compareBy<Entry> { it.count }.thenBy { it.lastUsed })
                    .take(entries.size - maxEntries)
                    .forEach { entries.remove(it.address.lowercase()) }
            }
            persistLocked(entries)
        }
    }

    /**
     * Addresses containing [query] (case-insensitive substring match on the
     * whole address), best-ranked first, excluding [exclude].
     */
    suspend fun suggest(
        query: String,
        limit: Int = 6,
        exclude: Collection<String> = emptyList(),
    ): List<String> {
        val needle = query.trim().lowercase()
        if (needle.isEmpty()) {
            return emptyList()
        }
        val excluded = exclude.map { it.lowercase() }.toSet()
        return mutex.withLock {
            loadLocked()
                .values
                .asSequence()
                .filter { it.address.lowercase().contains(needle) && it.address.lowercase() !in excluded }
                .sortedWith(compareByDescending<Entry> { it.count }.thenByDescending { it.lastUsed })
                .take(limit)
                .map { it.address }
                .toList()
        }
    }

    private suspend fun loadLocked(): MutableMap<String, Entry> {
        cache?.let { return it }
        val loaded =
            withContext(Dispatchers.IO) {
                if (!file.isFile) {
                    emptyList()
                } else {
                    runCatching { json.decodeFromString<List<Entry>>(file.readText()) }.getOrDefault(emptyList())
                }
            }
        return loaded.associateBy { it.address.lowercase() }.toMutableMap().also { cache = it }
    }

    private suspend fun persistLocked(entries: Map<String, Entry>) {
        withContext(Dispatchers.IO) {
            file.parentFile?.mkdirs()
            val temp = File(file.parentFile, "${file.name}.tmp")
            temp.writeText(json.encodeToString(entries.values.toList()))
            if (!temp.renameTo(file)) {
                temp.copyTo(file, overwrite = true)
                temp.delete()
            }
        }
    }

    companion object {
        const val DEFAULT_MAX_ENTRIES = 500
    }
}

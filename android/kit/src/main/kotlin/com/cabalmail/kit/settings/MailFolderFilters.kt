package com.cabalmail.kit.settings

import kotlinx.serialization.json.Json

/** The mail list's filter pill, as the synced preferences store it per folder. */
enum class MailFolderFilter(
    override val wire: String,
) : WireEnum {
    ALL("all"),
    UNREAD("unread"),
    FLAGGED("flagged"),
}

/**
 * The pill each mail folder's list opens on (sticky per folder; All until
 * the user picks another), keyed by folder path. Locally one JSON object
 * in DataStore; on the wire one `app`-map key per folder,
 * `filter:mail:<folder path>`, so the server's per-key merge applies: two
 * devices changing two folders' pills never clobber each other, and a
 * stale device can only overwrite the folders it knows. Limits and the
 * key shape mirror `lambda/api/set_preferences/function.py`.
 */
object MailFolderFilters {
    const val WIRE_PREFIX = "filter:mail:"

    private val json = Json

    /** Decodes the DataStore string; garbage or an unknown pill reads as no entry. */
    fun decode(stored: String?): Map<String, MailFolderFilter> {
        if (stored.isNullOrEmpty()) return emptyMap()
        val raw = runCatching { json.decodeFromString<Map<String, String>>(stored) }.getOrNull() ?: return emptyMap()
        return raw.mapNotNull { (path, value) -> wireEnum<MailFolderFilter>(value)?.let { path to it } }.toMap()
    }

    /** Encodes for DataStore, keys sorted so equal maps store identically. */
    fun encode(filters: Map<String, MailFolderFilter>): String =
        json.encodeToString(filters.entries.sortedBy { it.key }.associate { it.key to it.value.wire })

    /** The `app`-map entries the payload carries: one per folder. */
    fun toWire(filters: Map<String, MailFolderFilter>): Map<String, String> =
        filters.entries.associate { (path, filter) -> WIRE_PREFIX + path to filter.wire }

    /**
     * The `filter:mail:<path>` entries of a fetched `app` map merged over
     * [current]: the server wins per folder, and a folder it has no entry
     * for keeps its local pill. An empty path or an unknown pill is dropped.
     */
    fun mergeRemote(
        current: Map<String, MailFolderFilter>,
        app: Map<String, String>,
    ): Map<String, MailFolderFilter> =
        current +
            app.entries.mapNotNull { (key, value) ->
                if (!key.startsWith(WIRE_PREFIX)) return@mapNotNull null
                val path = key.removePrefix(WIRE_PREFIX)
                if (path.isEmpty()) return@mapNotNull null
                wireEnum<MailFolderFilter>(value)?.let { path to it }
            }
}

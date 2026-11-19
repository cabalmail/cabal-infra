package com.cabalmail.kit.rss

import com.cabalmail.kit.CabalmailException
import kotlinx.serialization.json.Json

/**
 * A feed item's flags of the user's own as an [RssStore] keeps them: a
 * sorted JSON list of palette slots on the item, and the queued changes to
 * them, one [PendingKind.FLAG] row per item and slot whose value says add
 * (true) or remove (false). The Kotlin sibling of the Apple kit's
 * `RssStoredFlags`.
 *
 * The item always shows what the queue will send. A local change writes
 * the item and its queue row together, and anything the server reports is
 * laid under the changes still queued ([overlaying]), slot by slot: a
 * change waiting here is newer than what the server had when it answered,
 * and only for its own slot.
 */
object RssStoredFlags {
    /** What an item with no flag stores, and the column's default. */
    const val NONE = "[]"

    fun encode(slots: Set<String>): String = Json.encodeToString(slots.sorted())

    /** Empty for anything that is not a JSON list of strings. */
    fun decode(json: String): Set<String> =
        runCatching { Json.decodeFromString<List<String>>(json) }.getOrDefault(emptyList()).toSet()

    /**
     * The server's flags for an item with that item's queued changes on
     * top: a slot with a queued add is set and one with a queued remove is
     * not, whatever the server said, and every other slot is the server's.
     */
    fun overlaying(
        queued: Map<String, Boolean>,
        server: Set<String>,
    ): Set<String> {
        if (queued.isEmpty()) return server
        val flags = server.toMutableSet()
        for ((slot, isSet) in queued) {
            if (isSet) flags += slot else flags -= slot
        }
        return flags
    }

    /**
     * Every queued flag change in [pending], by item ([com.cabalmail.kit.models.RssItem.id])
     * and then slot: true for an add. The queue holds one per item and
     * slot; were there two, the later one is the intent.
     */
    fun queued(pending: List<PendingMutation>): Map<String, Map<String, Boolean>> {
        val changes = HashMap<String, MutableMap<String, Boolean>>()
        for (row in pending) {
            if (row.kind != PendingKind.FLAG) continue
            changes.getOrPut("${row.feedId}#${row.sortKey}") { HashMap() }[row.slot] = row.value
        }
        return changes
    }
}

/**
 * `/rss_set_item_state` refused a whole call because it adds [slots] that
 * the account's flag list does not hold (`flag_not_in_palette`). The call
 * changed nothing. The drain answers it ([RssSyncEngine.drainPending]);
 * one it cannot answer leaves as the [CabalmailException.ApiError] it
 * arrived as ([asApiError]).
 */
class RssFlagRefusal(
    val slots: Set<String>,
    message: String,
) : Exception(message.ifEmpty { CODE }) {
    fun asApiError(): CabalmailException.ApiError =
        CabalmailException.ApiError(
            httpStatus = HTTP_BAD_REQUEST,
            message = message.orEmpty(),
            code = CODE,
            flags = slots.sorted(),
        )

    companion object {
        const val CODE = "flag_not_in_palette"
        private const val HTTP_BAD_REQUEST = 400
    }
}

/**
 * What became of the settings this device owes the server when the feed
 * queue asked for them to be sent ([RssSyncEngine.unsentSettingsPush]).
 *
 * The server refuses a flag add for a slot its copy of the flag list does
 * not hold. Usually the flag was deleted, here or on another device, and
 * the queue drops the add. But a flag created while the settings could not
 * be sent is in this device's list and not yet in the server's, so the
 * refusal says only that the settings have not gone yet. The queue asks
 * before it drops anything.
 */
enum class RssUnsentSettings {
    /** No change to the flag list was waiting: the server's list is this device's, so the refusal stands. */
    NOTHING_UNSENT,

    /** A change to the flag list was waiting and the server has it now: the refused adds may go if sent again. */
    SENT,

    /** A change to the flag list is waiting and could not be sent: the adds wait too. */
    STILL_UNSENT,
}

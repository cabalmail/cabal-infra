package com.cabalmail.kit.settings

import kotlinx.serialization.Serializable

/**
 * What this device knows of the account's settings row and what it owes
 * it: the row as last seen, and the keys changed here that the server has
 * not taken. [PreferencesRepository] keeps one in the store beside the
 * values, so a change the app could not send survives a relaunch. The
 * Kotlin sibling of the Apple kit's `SettingsSyncLedger`; the server's
 * side of the contract is `docs/settings-sync.md`.
 *
 * It exists so that a device sends only what was changed on it. A push
 * used to carry every key at this device's values, so a device that had
 * not seen another device's change, or had never read the row at all, put
 * its own copy over the account's (#2452, #2464). With the keys known, a
 * push carries those alone, and a pull applies to every other key.
 *
 * Keys are the ones [PreferencesWire.toValues] gives. Pure bookkeeping: it
 * reads and writes nothing itself, and every operation answers a new
 * ledger.
 *
 * @property hasRow True once this device has read the account's row (a
 *   pull, or the row a refused push was answered with). Until then
 *   nothing is sent.
 * @property version The row's version as last answered: what the next
 *   push says it was built on. Null until the row is read, and with a
 *   server that predates the version.
 * @property base The row's values as the server last answered or took them.
 * @property unsent The keys changed on this device that the server has
 *   not taken.
 */
@Serializable
data class SettingsSyncLedger(
    val hasRow: Boolean = false,
    val version: Int? = null,
    val base: Map<String, String> = emptyMap(),
    val unsent: Set<String> = emptySet(),
) {
    /** Whether anything is owed to the server. */
    val hasUnsent: Boolean get() = unsent.isNotEmpty()

    /**
     * A user's edit changed [keys]; [values] is the settings after it. A
     * key put back to what the server holds is no longer owed.
     */
    fun edited(
        keys: Set<String>,
        values: Map<String, String>,
    ): SettingsSyncLedger {
        val owed = unsent + keys
        if (!hasRow) return copy(unsent = owed)
        return copy(
            unsent =
                owed.filterTo(mutableSetOf()) { key ->
                    val mine = values[key]
                    val theirs = base[key]
                    mine == null || theirs == null || !same(key, mine, theirs)
                },
        )
    }

    /** The part of [values] to send: the unsent keys at their values now. */
    fun changes(values: Map<String, String>): Map<String, String> = values.filterKeys { it in unsent }

    /**
     * The server took [sent] and answered [version]. A key changed again
     * while the request was out ([values] is the settings now) stays owed.
     */
    fun took(
        sent: Map<String, String>,
        version: Int?,
        values: Map<String, String>,
    ): SettingsSyncLedger =
        copy(
            version = version,
            base = base + sent,
            unsent = unsent.filterTo(mutableSetOf()) { key -> key !in sent || values[key] != sent[key] },
        )

    /** A [rebase]: the ledger after it, and the values to write into the settings. */
    data class Rebased(
        val ledger: SettingsSyncLedger,
        val apply: Map<String, String>,
    )

    /**
     * Takes the row as the server answered it ([row] at [rowVersion]),
     * from a pull or with a refused push. The values to apply are the
     * row's for every key not owed, and for the flag list when it is
     * owed, the two lists merged ([FlagPalette.merged]). [values] is the
     * settings as they are now. An owed key the row already holds at this
     * device's value is settled.
     */
    fun rebase(
        row: Map<String, String>,
        rowVersion: Int?,
        values: Map<String, String>,
    ): Rebased {
        val apply = mutableMapOf<String, String>()
        val after = values.toMutableMap()
        for ((key, theirs) in row) {
            val taken =
                when {
                    key !in unsent -> theirs
                    key == PreferencesWire.AppKey.FLAG_PALETTE -> mergedPalette(values[key], theirs)
                    else -> null
                } ?: continue
            apply[key] = taken
            after[key] = taken
        }
        val owed =
            unsent.filterTo(mutableSetOf()) { key ->
                val mine = after[key] ?: return@filterTo false
                val theirs = row[key] ?: return@filterTo true
                !same(key, mine, theirs)
            }
        return Rebased(SettingsSyncLedger(hasRow = true, version = rowVersion, base = row, unsent = owed), apply)
    }

    /**
     * The owed flag list merged with the row's, as its wire string, or
     * null when either does not parse (the owed list then stays as it is).
     */
    private fun mergedPalette(
        mine: String?,
        theirs: String,
    ): String? {
        val here = mine?.let(FlagPalette::decode) ?: return null
        val there = FlagPalette.decode(theirs) ?: return null
        val was = base[PreferencesWire.AppKey.FLAG_PALETTE]?.let(FlagPalette::decode).orEmpty()
        return FlagPalette.encode(FlagPalette.merged(base = was, mine = here, theirs = there))
    }
}

/**
 * Whether two wire values of [key] say the same thing. The flag list is
 * compared as a list: the server stores it in its own spelling. Top-level
 * and not in a companion: the class is serializable, and its generated
 * serializer lives on the companion, which must stay reachable.
 */
private fun same(
    key: String,
    one: String,
    other: String,
): Boolean {
    if (one == other) return true
    if (key != PreferencesWire.AppKey.FLAG_PALETTE) return false
    val first = FlagPalette.decode(one) ?: return false
    return first == FlagPalette.decode(other)
}

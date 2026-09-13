package com.cabalmail.kit.settings

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Test

/**
 * The per-folder sticky pill map: its DataStore codec, its one-key-per-
 * folder wire form, and the per-folder merge of a fetched `app` map.
 */
class MailFolderFiltersTest {
    private val filters = mapOf("INBOX" to MailFolderFilter.UNREAD, "Archive/2026" to MailFolderFilter.FLAGGED)

    @Test
    fun `codec round-trips with sorted keys and tolerates garbage`() {
        val stored = MailFolderFilters.encode(filters)
        assertEquals("""{"Archive/2026":"flagged","INBOX":"unread"}""", stored)
        assertEquals(filters, MailFolderFilters.decode(stored))
        assertEquals(emptyMap<String, MailFolderFilter>(), MailFolderFilters.decode(null))
        assertEquals(emptyMap<String, MailFolderFilter>(), MailFolderFilters.decode("not json"))
        // An unknown pill (a feed one, say) drops its entry, not the map.
        assertEquals(
            mapOf("Drafts" to MailFolderFilter.ALL),
            MailFolderFilters.decode("""{"INBOX":"favorite","Drafts":"all"}"""),
        )
    }

    @Test
    fun `wire form is one prefixed key per folder`() {
        assertEquals(
            mapOf("filter:mail:INBOX" to "unread", "filter:mail:Archive/2026" to "flagged"),
            MailFolderFilters.toWire(filters),
        )
        assertEquals(emptyMap<String, String>(), MailFolderFilters.toWire(emptyMap()))
    }

    @Test
    fun `remote entries merge per folder over the current map`() {
        val current = mapOf("Local" to MailFolderFilter.FLAGGED, "INBOX" to MailFolderFilter.ALL)
        val merged =
            MailFolderFilters.mergeRemote(
                current,
                mapOf(
                    "filter:mail:INBOX" to "unread",
                    "filter:mail:Junk" to "sometimes",
                    "filter:mail:" to "all",
                    "theme" to "dark",
                ),
            )
        assertEquals(mapOf("Local" to MailFolderFilter.FLAGGED, "INBOX" to MailFolderFilter.UNREAD), merged)
    }
}

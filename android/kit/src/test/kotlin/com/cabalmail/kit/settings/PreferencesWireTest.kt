package com.cabalmail.kit.settings

import com.cabalmail.kit.compose.SignatureFormatter
import com.cabalmail.kit.models.Preferences
import com.cabalmail.kit.models.RssItemFilter
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

class PreferencesWireTest {
    @Test
    fun `payload carries every synced key and mirrors explicit theme to the flat field`() {
        val update =
            PreferencesWire.toUpdate(
                AppPreferences(theme = AppTheme.DARK, signature = "— me", defaultFromAddress = null),
            )
        assertEquals("dark", update.theme)
        assertEquals("forest", update.accent)
        assertEquals("compact", update.density)
        assertEquals("", update.name)
        val app = update.app!!
        assertEquals("dark", app["theme"])
        assertEquals("", app["default_from_address"])
        assertEquals("— me", app["signature"])
        assertEquals("manual", app["mark_as_read"])
        assertEquals(
            setOf(
                "mark_as_read",
                "load_remote_content",
                "default_from_address",
                "signature",
                "dispose_action",
                "dispose_advance",
                "theme",
                "default_body_render_mode",
                "folder_count_display",
            ),
            app.keys,
        )
        assertEquals("next_unread", app["dispose_advance"])
        assertNull(PreferencesWire.toUpdate(AppPreferences(theme = AppTheme.SYSTEM)).theme)
    }

    @Test
    fun `remote applies over current, seeds theme from the flat field, keeps local fields`() {
        val current = AppPreferences(dynamicColor = false, defaultFromAddress = "old@x", signature = "s")
        val remote =
            Preferences(
                theme = "dark",
                accent = "plum",
                density = "roomy",
                name = "Ann",
                app =
                    mapOf(
                        "mark_as_read" to "on_open",
                        "default_from_address" to "",
                        "bogus" to "x",
                        "dispose_action" to "nonsense",
                    ),
            )
        val merged = PreferencesWire.applyRemote(current, remote)
        assertEquals("Ann", merged.displayName)
        assertEquals(Accent.PLUM, merged.accent)
        assertEquals(Density.ROOMY, merged.density)
        assertEquals(AppTheme.DARK, merged.theme)
        assertEquals(MarkAsRead.ON_OPEN, merged.markAsRead)
        assertNull(merged.defaultFromAddress)
        assertEquals(DisposeAction.ARCHIVE, merged.disposeAction)
        assertEquals("s", merged.signature)
        assertEquals(false, merged.dynamicColor)
        // app-map theme wins over the flat field
        assertEquals(
            AppTheme.SYSTEM,
            PreferencesWire.applyRemote(current, remote.copy(app = mapOf("theme" to "system"))).theme,
        )
        // absent default_from_address leaves the current value
        assertEquals("old@x", PreferencesWire.applyRemote(current, Preferences()).defaultFromAddress)
    }

    @Test
    fun `dispose advance round-trips and survives an absent or bogus remote value`() {
        val current = AppPreferences(disposeAdvance = DisposeAdvance.PREVIOUS_UNREAD)
        assertEquals(
            DisposeAdvance.PREVIOUS_UNREAD,
            PreferencesWire.applyRemote(current, Preferences()).disposeAdvance,
        )
        assertEquals(
            DisposeAdvance.PREVIOUS_UNREAD,
            PreferencesWire
                .applyRemote(current, Preferences(app = mapOf("dispose_advance" to "nonsense")))
                .disposeAdvance,
        )
        assertEquals(
            DisposeAdvance.FIRST_UNREAD,
            PreferencesWire
                .applyRemote(current, Preferences(app = mapOf("dispose_advance" to "first_unread")))
                .disposeAdvance,
        )
        assertEquals(
            "previous_unread",
            PreferencesWire.toUpdate(current).app!!["dispose_advance"],
        )
    }

    @Test
    fun `mail folder pills ride as their own keys and merge per folder on the way back`() {
        val current = AppPreferences(mailFolderFilters = mapOf("INBOX" to MailFolderFilter.UNREAD))
        val app = PreferencesWire.toUpdate(current).app!!
        assertEquals("unread", app["filter:mail:INBOX"])
        // No map key of its own: the flat-key set the first test pins is unchanged.
        assertNull(app["mail_folder_filters"])
        val merged =
            PreferencesWire.applyRemote(
                current,
                Preferences(app = mapOf("filter:mail:Archive" to "flagged", "filter:mail:INBOX" to "all")),
            )
        assertEquals(
            mapOf("INBOX" to MailFolderFilter.ALL, "Archive" to MailFolderFilter.FLAGGED),
            merged.mailFolderFilters,
        )
        // A pull with no entries leaves the local map alone.
        assertEquals(current.mailFolderFilters, PreferencesWire.applyRemote(current, Preferences()).mailFolderFilters)
    }

    @Test
    fun `signature seeding matches the Apple layout`() {
        assertEquals("", SignatureFormatter.seedBody("", ""))
        assertEquals("\n\n-- \nsig", SignatureFormatter.seedBody("", "sig"))
        assertEquals("\n-- \nsig\n\n---\nquote", SignatureFormatter.seedBody("\n\n---\nquote", "sig"))
        assertEquals("\n-- \nsig\nbody", SignatureFormatter.seedBody("body", "sig"))
    }

    @Test
    fun `feed reader keys stay off the wire until set and then ride, defaults included`() {
        val untouched = PreferencesWire.toUpdate(AppPreferences()).app!!
        assertTrue(untouched.keys.none { it.startsWith("rss_") || it.startsWith("filter:feeds") })
        assertEquals(MarkAsRead.MANUAL, AppPreferences().effectiveRssMarkAsRead)
        assertEquals(RssItemFilter.UNREAD, AppPreferences().effectiveFeedsAllFilter)

        // A user choice rides, and keeps riding when set back to the default.
        val chosen = AppPreferences(rssMarkAsRead = MarkAsRead.ON_OPEN, feedsAllFilter = RssItemFilter.ALL)
        assertEquals("on_open", PreferencesWire.toUpdate(chosen).app!!["rss_mark_as_read"])
        assertEquals("all", PreferencesWire.toUpdate(chosen).app!!["filter:feeds:all"])
        val reverted = chosen.copy(rssMarkAsRead = MarkAsRead.MANUAL, feedsAllFilter = RssItemFilter.UNREAD)
        assertEquals("manual", PreferencesWire.toUpdate(reverted).app!!["rss_mark_as_read"])
        assertEquals("unread", PreferencesWire.toUpdate(reverted).app!!["filter:feeds:all"])

        // A fetched map carrying the keys applies them (and so makes them ride); a mail-only pill
        // name and an unknown mode leave the current value.
        val remote = Preferences(app = mapOf("rss_mark_as_read" to "on_open", "filter:feeds:all" to "favorite"))
        val merged = PreferencesWire.applyRemote(AppPreferences(), remote)
        assertEquals(MarkAsRead.ON_OPEN, merged.rssMarkAsRead)
        assertEquals(RssItemFilter.FAVORITE, merged.feedsAllFilter)
        val junk = Preferences(app = mapOf("rss_mark_as_read" to "later", "filter:feeds:all" to "flagged"))
        val kept = PreferencesWire.applyRemote(merged, junk)
        assertEquals(MarkAsRead.ON_OPEN, kept.rssMarkAsRead)
        assertEquals(RssItemFilter.FAVORITE, kept.feedsAllFilter)
        assertNull(PreferencesWire.applyRemote(AppPreferences(), junk).rssMarkAsRead)
    }
}

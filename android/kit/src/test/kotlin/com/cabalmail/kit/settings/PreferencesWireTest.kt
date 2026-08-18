package com.cabalmail.kit.settings

import com.cabalmail.kit.compose.SignatureFormatter
import com.cabalmail.kit.models.Preferences
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNull
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
                "theme",
                "default_body_render_mode",
                "folder_count_display",
            ),
            app.keys,
        )
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
    fun `signature seeding matches the Apple layout`() {
        assertEquals("", SignatureFormatter.seedBody("", ""))
        assertEquals("\n\n-- \nsig", SignatureFormatter.seedBody("", "sig"))
        assertEquals("\n-- \nsig\n\n---\nquote", SignatureFormatter.seedBody("\n\n---\nquote", "sig"))
        assertEquals("\n-- \nsig\nbody", SignatureFormatter.seedBody("body", "sig"))
    }
}

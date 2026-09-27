package com.cabalmail.android.ui.settings

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import java.io.File

/**
 * #1730: the sort *direction* was drawn as a switch labelled "Newest first"
 * on a control that also sorts by sender and by subject, and the same string
 * was a real date-meaning option in the feed list's Order menu one tab away.
 *
 * Two rules here. The mapping between the stored boolean and the pair the
 * surfaces draw is pure and tested directly; which string a Compose surface
 * draws has no unit seam, so the second half is a source scan — the same
 * shape as [com.cabalmail.android.ui.mail.DisposeSurfaceScanTest], and for
 * the same reason. Gradle runs unit tests from the module directory, so the
 * repository root is two levels up.
 */
class SortDirectionTest {
    private val android: File = File(File("../..").canonicalFile, "android/app/src/main")

    private fun source(path: String): String = File(android, "kotlin/com/cabalmail/android/$path").readText()

    private val strings: String get() = File(android, "res/values/strings.xml").readText()

    /** Block and line comments cut, so a doc comment naming a string is not a use of it. */
    private fun code(text: String): String =
        text.replace(Regex("""(?s)/\*.*?\*/"""), "").lines().joinToString("\n") { it.substringBefore("//") }

    @Test
    fun `the stored boolean round-trips through the pair`() {
        assertEquals(SortDirection.DESCENDING, SortDirection.of(true))
        assertEquals(SortDirection.ASCENDING, SortDirection.of(false))
        assertTrue(SortDirection.DESCENDING.descending)
        assertFalse(SortDirection.ASCENDING.descending)
        SortDirection.entries.forEach { assertEquals(it, SortDirection.of(it.descending)) }
    }

    @Test
    fun `no surface draws the date-shaped string any more`() {
        listOf("ui/settings/SettingsScreen.kt", "ui/mail/MessageListScreen.kt").forEach { path ->
            assertFalse(
                code(source(path)).contains("R.string.sort_descending"),
                "$path still names a date ordering for a sort that can be by sender or subject (#1730)",
            )
        }
        assertFalse(strings.contains("""name="sort_descending""""))
    }

    @Test
    fun `both surfaces draw the direction as a pair`() {
        listOf("ui/settings/SettingsScreen.kt", "ui/mail/MessageListScreen.kt").forEach { path ->
            assertTrue(
                code(source(path)).contains("SortDirection.entries"),
                "$path should offer both directions, not toggle one of them",
            )
        }
    }

    /**
     * The collision itself: "Newest first" is legitimate on a feed list, whose
     * items are ordered by date and nothing else. What it must not be is two
     * strings, one of which means "descending".
     */
    @Test
    fun `only the feed order option is named for dates`() {
        val named = Regex("""<string name="([^"]+)">Newest first</string>""")
            .findAll(strings)
            .map { it.groupValues[1] }
            .toList()
        assertEquals(listOf("feed_order_newest_first"), named)
    }

    @Test
    fun `the direction strings the surfaces ask for exist`() {
        listOf("sort_direction", "opt_sort_ascending", "opt_sort_descending").forEach {
            assertTrue(strings.contains("""name="$it""""), "strings.xml is missing $it")
        }
    }

    /** Floor: a mis-rooted read finds nothing and passes everything above. */
    @Test
    fun `the sources are readable`() {
        assertTrue(source("ui/settings/SettingsScreen.kt").contains("fun SettingsScreen"))
        assertTrue(strings.contains("<resources"))
    }
}

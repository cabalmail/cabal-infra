package com.cabalmail.android.ui.theme

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import java.io.File

/**
 * #1612: two star toggles carried their state by tint alone. The Addresses
 * favorite meant to switch glyphs but picked `Icons.Outlined.Star`, which in
 * `material-icons-core` is as solid as `Icons.Filled.Star`; the feed reader's
 * Favorite drew `Icons.Default.Star` either way. Which glyph a painter draws
 * has no unit-test seam, so these hold the source to the rule instead.
 * Gradle runs unit tests from the module directory, so the repository root
 * is two levels up.
 */
class StarToggleScanTest {
    private val mainSources: File =
        File(File("../..").canonicalFile, "android/app/src/main/kotlin/com/cabalmail/android")

    private fun source(path: String): String = File(mainSources, path).readText()

    /** Block and line comments cut, so a doc comment naming the glyph is not a use of it. */
    private fun code(text: String): String =
        text.replace(Regex("""(?s)/\*.*?\*/"""), "").lines().joinToString("\n") { it.substringBefore("//") }

    private val solidOnlyStar = Regex("""\bIcons\.(Outlined|Rounded|Sharp|TwoTone)\.Star\b""")

    @Test
    fun `no source draws a core style star that looks hollow but is not`() {
        val files = mainSources.walkTopDown().filter { it.extension == "kt" }.toList()
        assertTrue(files.size > 80, "scanned only ${files.size} files; is the source root right?")
        val offenders =
            files
                .filter { solidOnlyStar.containsMatchIn(code(it.readText())) }
                .map { it.relativeTo(mainSources).path }
                .sorted()
        assertEquals(emptyList<String>(), offenders)
    }

    @Test
    fun `the detector matches a use and ignores prose and the filled star`() {
        assertTrue(solidOnlyStar.containsMatchIn(code("if (on) Icons.Filled.Star else Icons.Outlined.Star,")))
        assertTrue(solidOnlyStar.containsMatchIn(code("Icon(Icons.Rounded.Star, null)")))
        assertFalse(solidOnlyStar.containsMatchIn(code("// its `Icons.Outlined.Star` is solid")))
        assertFalse(solidOnlyStar.containsMatchIn(code("/**\n * its `Icons.Outlined.Star` is solid\n */\nfun f() = 1")))
        assertFalse(solidOnlyStar.containsMatchIn(code("Icon(Icons.Filled.Star, null)")))
        assertFalse(solidOnlyStar.containsMatchIn(code("Icons.Outlined.StarHalf")))
    }

    @Test
    fun `the Addresses favorite star draws its state by shape`() {
        assertTrue(
            source("ui/addresses/AddressesScreen.kt").contains("starTogglePainter(address.favorite)"),
            "the Addresses favorite toggle must draw through starTogglePainter",
        )
    }

    @Test
    fun `the feed reader's Favorite star draws its state by shape`() {
        assertTrue(
            source("ui/feeds/FeedItemDetailScreen.kt").contains("starTogglePainter(item.isFavorite)"),
            "the feed reader's Favorite toggle must draw through starTogglePainter",
        )
    }
}

package com.cabalmail.android.ui.mail

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import java.io.File

/**
 * #1619 and #1628: the dispose swipe moved a message onto the folder it was
 * already in, and said so, because each surface composed its own destination
 * from the "Dispose action" preference instead of reconciling it against the
 * row's folder through [DisposeIntent]. The message list was fixed first and
 * Search kept the defect, so the rule that matters is not "this one screen
 * is right" but "no dispose surface resolves its own destination". Which
 * folder a running screen passes has no unit-test seam, so this holds the
 * source to that rule. Gradle runs unit tests from the module directory, so
 * the repository root is two levels up.
 */
class DisposeSurfaceScanTest {
    private val mainSources: File =
        File(File("../..").canonicalFile, "android/app/src/main/kotlin/com/cabalmail/android")

    private fun source(path: String): String = File(mainSources, path).readText()

    /** Block and line comments cut, so a doc comment naming a call is not one. */
    private fun code(text: String): String =
        text.replace(Regex("""(?s)/\*.*?\*/"""), "").lines().joinToString("\n") { it.substringBefore("//") }

    /**
     * The argument lists of every `SwipeRow(...)` *call* in [text], by paren
     * depth — a `\(([^)]*)\)` would stop at the first nested call's `)` and
     * report an argument list that is missing everything after it.
     */
    private fun swipeRowCallArguments(text: String): List<String> =
        Regex("""(?<!fun )\bSwipeRow\(""")
            .findAll(text)
            .map { match ->
                var depth = 0
                var index = match.range.last
                while (index < text.length) {
                    when (text[index]) {
                        '(' -> depth++
                        ')' -> if (--depth == 0) return@map text.substring(match.range.last + 1, index)
                    }
                    index++
                }
                error("unbalanced SwipeRow( at ${match.range.first}")
            }.toList()

    @Test
    fun `every mail swipe row is given its row's dispose intent`() {
        val files = mainSources.walkTopDown().filter { it.extension == "kt" }.toList()
        assertTrue(files.size > 80, "scanned only ${files.size} files; is the source root right?")
        val callers =
            files
                .map { it.relativeTo(mainSources).path to swipeRowCallArguments(code(it.readText())) }
                .filter { (_, calls) -> calls.isNotEmpty() }
                .sortedBy { it.first }
        // The inventory, not just the offenders: a new swipe-row surface
        // shows up here rather than being silently exempt.
        assertEquals(
            listOf("ui/mail/MessageListScreen.kt" to 1, "ui/mail/SearchScreen.kt" to 1),
            callers.map { (path, calls) -> path to calls.size },
        )
        val offenders =
            callers
                .filterNot { (_, calls) -> calls.all { it.contains("disposeIntent =") } }
                .map { it.first }
        assertEquals(emptyList<String>(), offenders, "a mail swipe row left to the folder-blind default")
    }

    @Test
    fun `every mail dispose resolves the intent against the acting folder`() {
        listOf("ui/mail/MessageListViewModel.kt", "ui/mail/SearchViewModel.kt").forEach { path ->
            assertTrue(
                code(source(path)).contains("DisposeIntent.standard("),
                "$path disposes without reconciling the preference against the folder",
            )
        }
    }

    @Test
    fun `the detector reads whole argument lists and ignores the declaration and prose`() {
        val nested =
            """
            SwipeRow(
                isSeen = envelope.isSeen,
                onDispose = { dispose(setOf(envelope.id), extra(1, 2)) },
                disposeIntent = disposeIntent,
            ) { Row() }
            """.trimIndent()
        assertEquals(1, swipeRowCallArguments(nested).size)
        assertTrue(swipeRowCallArguments(nested).single().contains("disposeIntent ="))
        assertTrue(swipeRowCallArguments("internal fun SwipeRow(\n    isSeen: Boolean,\n)").isEmpty())
        assertTrue(swipeRowCallArguments(code("// SwipeRow(isSeen = true)")).isEmpty())
        assertTrue(swipeRowCallArguments(code("/**\n * [SwipeRow(isSeen)]\n */")).isEmpty())
        assertFalse(swipeRowCallArguments("SwipeRow(isSeen = true)").single().contains("disposeIntent ="))
        assertTrue(swipeRowCallArguments("FeedSwipeRow(isSeen = true)").isEmpty())
    }
}

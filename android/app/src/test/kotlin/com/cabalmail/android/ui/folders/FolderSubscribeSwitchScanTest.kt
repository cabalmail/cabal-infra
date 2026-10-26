package com.cabalmail.android.ui.folders

import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import java.io.File

/**
 * #2210: every row's subscribe switch was an unnamed accessibility focus
 * stop -- a `ListItem`'s trailing slot is not merged into the row, so seven
 * folders meant seven switches a screen reader could only call "switch, on".
 * What a node announces has no JVM unit-test seam (no Compose or Robolectric
 * harness in this module), so this holds the source and the string to the
 * rule instead, the way `StarToggleScanTest` does for the star glyphs.
 * Gradle runs unit tests from the module directory, so the repository root
 * is two levels up.
 */
class FolderSubscribeSwitchScanTest {
    private val repo: File = File("../..").canonicalFile
    private val screen: String =
        File(repo, "android/app/src/main/kotlin/com/cabalmail/android/ui/folders/FoldersAdminScreen.kt").readText()
    private val strings: String = File(repo, "android/app/src/main/res/values/strings.xml").readText()

    /** The `Switch(...)` call's own arguments, from its opening paren to the matching one. */
    private fun switchCall(source: String): String {
        val start = source.indexOf("Switch(")
        assertTrue(start >= 0, "no Switch( in the source")
        var depth = 0
        val open = source.indexOf('(', start)
        var i = open
        while (i < source.length) {
            when (source[i]) {
                '(' -> depth++
                ')' -> {
                    depth--
                    if (depth == 0) return source.substring(open, i + 1)
                }
            }
            i++
        }
        error("unbalanced parentheses after Switch(")
    }

    @Test
    fun `the subscribe switch carries a name of its own`() {
        assertTrue(
            switchCall(screen).contains("contentDescription"),
            "the Folders row's Switch must name itself; a trailing-slot switch is its own focus stop",
        )
    }

    /**
     * The name has to carry the folder: the headline that would have said
     * which folder is a separate focus stop, and the supporting line says
     * "22 messages" once the count loads.
     */
    @Test
    fun `the name is per folder`() {
        assertTrue(
            screen.contains("stringResource(R.string.folders_subscribe_switch, folder)"),
            "the switch's name must be formatted with the row's folder",
        )
        assertTrue(
            strings.contains("""<string name="folders_subscribe_switch">Subscribe to %1${'$'}s</string>"""),
            "folders_subscribe_switch must take the folder as its one argument",
        )
    }

    /** The scan reads a real call, and a switch with no name does not pass it. */
    @Test
    fun `the detector reads the arguments and rejects an unnamed switch`() {
        val named =
            """
            Switch(
                checked = subscribed,
                onCheckedChange = { viewModel.setSubscribed(folder, it) },
                modifier = Modifier.semantics { contentDescription = switchName },
            )
            """.trimIndent()
        val unnamed =
            """
            Switch(
                checked = subscribed,
                onCheckedChange = { viewModel.setSubscribed(folder, it) },
                enabled = !busy,
            )
            if (viewModel.canDelete(folder)) {
                IconButton(onClick = { menuFor = folder }) {
                    Icon(Icons.Default.MoreVert, contentDescription = stringResource(R.string.more_actions))
                }
            }
            """.trimIndent()
        assertTrue(switchCall(named).contains("contentDescription"))
        assertFalse(
            switchCall(unnamed).contains("contentDescription"),
            "the call's own arguments end at its closing paren, so a named sibling must not count",
        )
    }
}

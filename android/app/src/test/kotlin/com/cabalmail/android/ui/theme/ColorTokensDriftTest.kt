package com.cabalmail.android.ui.theme

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import java.io.File

/**
 * `res/values/color_tokens.xml` and `ui/theme/ColorTokens.kt` are generated
 * from `design/color-tokens.json` by `scripts/generate-color-tokens.py`.
 * This holds the tree to that file: a hand edit to either output, or a token
 * change without a regeneration, fails here rather than drifting from the
 * Apple and web exports. Gradle runs unit tests from the module directory,
 * so the repository root is two levels up.
 */
class ColorTokensDriftTest {
    private val repoRoot: File = File("../..").canonicalFile

    @Test
    fun `generated colour tokens match the token file`() {
        val generator = File(repoRoot, "scripts/generate-color-tokens.py")
        assertTrue(generator.isFile, "generator missing at $generator")
        val process =
            ProcessBuilder("python3", generator.path, "--check")
                .directory(repoRoot)
                .redirectErrorStream(true)
                .start()
        val output = process.inputStream.bufferedReader().readText()
        val status = process.waitFor()
        assertEquals(0, status, "generated colour tokens are out of date:\n$output")
    }
}

package com.cabalmail.android.ui.rules

import android.text.InputType
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import com.cabalmail.kit.models.RuleField
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

/**
 * What a rule condition value asks of the IME (#2038).
 *
 * `autoCorrectEnabled = false` landed with #2023 and was not enough: Gboard
 * reads a missing `TYPE_TEXT_FLAG_AUTO_CORRECT` as "the app corrects for
 * itself" and kept rewriting Subject and Body values. The input types below
 * are the ones read live off `dumpsys input_method` on an Android 15
 * emulator: `0x1` for Subject and Body, `0x21` for From.
 */
class RuleConditionImeTest {
    private val plainText = 0x1
    private val emailText = 0x21

    @Test
    fun `no condition field corrects or capitalizes, and only addresses take the email keyboard`() {
        for (field in RuleField.entries) {
            val options = ruleConditionKeyboardOptions(field)
            assertFalse(options.autoCorrectEnabled!!, "$field asks for auto-correct")
            assertEquals(KeyboardCapitalization.None, options.capitalization, "$field capitalizes")
            assertEquals(
                if (field.holdsAddresses) KeyboardType.Email else KeyboardType.Text,
                options.keyboardType,
                "$field takes the wrong keyboard",
            )
        }
    }

    @Test
    fun `the flag Gboard reads is the one the report names`() {
        assertEquals(0x80000, InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS)
    }

    @Test
    fun `both measured input types come back refusing suggestions`() {
        for (measured in listOf(plainText, emailText)) {
            val amended = withoutImeSuggestions(measured)
            assertTrue(
                amended and InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS != 0,
                "0x${measured.toString(16)} still allows suggestions",
            )
            assertEquals(
                measured and InputType.TYPE_MASK_CLASS,
                amended and InputType.TYPE_MASK_CLASS,
                "0x${measured.toString(16)} changed class",
            )
            assertEquals(
                measured and InputType.TYPE_MASK_VARIATION,
                amended and InputType.TYPE_MASK_VARIATION,
                "0x${measured.toString(16)} changed variation",
            )
            assertEquals(
                0,
                amended and InputType.TYPE_TEXT_FLAG_AUTO_CORRECT,
                "0x${measured.toString(16)} asked for auto-correct back",
            )
        }
    }

    /**
     * The negative control, and the defect itself: what Compose hands the
     * IME is exactly the two types measured live, and neither of them
     * refuses suggestions on its own. Without this, the assertions above
     * would pass against an unchanged input type on any platform whose
     * `KeyboardOptions` already set the flag.
     */
    @Test
    fun `neither measured input type refuses suggestions on its own`() {
        for (measured in listOf(plainText, emailText)) {
            assertEquals(
                0,
                measured and InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS,
                "0x${measured.toString(16)} already refused suggestions, so the fix is untested",
            )
        }
    }

    @Test
    fun `amending an already-amended type changes nothing`() {
        val once = withoutImeSuggestions(plainText)
        assertEquals(once, withoutImeSuggestions(once))
    }
}

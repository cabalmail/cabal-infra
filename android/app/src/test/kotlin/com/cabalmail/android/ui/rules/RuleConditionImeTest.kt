package com.cabalmail.android.ui.rules

import android.text.InputType
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import com.cabalmail.kit.models.RuleField
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNotEquals
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

/**
 * What a rule condition value asks of the IME (#2038).
 *
 * Every number here was read off `dumpsys input_method` on an Android 15
 * emulator while the value was focused, and every one of them has a typing
 * arm behind it. [plainText] and [emailText] are what Compose derives from
 * [ruleConditionKeyboardOptions]; [flagOnly] is what the first fix shipped
 * and Gboard 18.5.4 corrected anyway; [filterText] is what ships now and
 * took `wont becuase recieve ` and `becuase recieve thier ` verbatim while
 * the rule Name field beside it, at `0x8001`, was corrected 3 of 3.
 */
class RuleConditionImeTest {
    private val plainText = 0x1
    private val emailText = 0x21
    private val flagOnly = 0x80001
    private val filterText = 0x800b1
    private val filterEmail = 0x80021

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
    fun `the bits the live reads are written in`() {
        assertEquals(0x80000, InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS)
        assertEquals(0xb0, InputType.TYPE_TEXT_VARIATION_FILTER)
    }

    @Test
    fun `each field edits under the type measured verbatim for it`() {
        assertEquals(filterText, ruleConditionInputType(RuleField.SUBJECT, plainText))
        assertEquals(filterText, ruleConditionInputType(RuleField.BODY, plainText))
        for (field in listOf(RuleField.FROM, RuleField.TO, RuleField.CC)) {
            assertEquals(filterEmail, ruleConditionInputType(field, emailText), "$field lost the email variation")
        }
    }

    @Test
    fun `every field carries a variation and refuses suggestions`() {
        for (field in RuleField.entries) {
            val derived = if (field.holdsAddresses) emailText else plainText
            val amended = ruleConditionInputType(field, derived)
            assertNotEquals(0, amended and InputType.TYPE_MASK_VARIATION, "$field edits with no variation at all")
            assertTrue(
                amended and InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS != 0,
                "$field still allows suggestions",
            )
            assertEquals(
                derived and InputType.TYPE_MASK_CLASS,
                amended and InputType.TYPE_MASK_CLASS,
                "$field changed class",
            )
            assertEquals(0, amended and InputType.TYPE_TEXT_FLAG_AUTO_CORRECT, "$field asked for auto-correct back")
        }
    }

    /**
     * The negative control, and the defect itself. The first fix's type
     * ([flagOnly]) was measured being corrected, so a free-text field that
     * still edits under it is the bug, not the fix -- and both types
     * Compose derives carry no variation of their own, so without this the
     * assertions above would pass against an unamended input type.
     */
    @Test
    fun `nothing measured as corrected is what a free-text field ends up with`() {
        for (field in listOf(RuleField.SUBJECT, RuleField.BODY)) {
            assertNotEquals(
                flagOnly,
                ruleConditionInputType(field, plainText),
                "$field edits under the type Gboard 18.5.4 was measured correcting",
            )
        }
        assertEquals(
            0,
            plainText and InputType.TYPE_MASK_VARIATION,
            "0x1 already had a variation, so the fix is untested",
        )
        assertEquals(
            0,
            flagOnly and InputType.TYPE_MASK_VARIATION,
            "0x80001 already had a variation, so the fix is untested",
        )
    }

    @Test
    fun `amending an already-amended type changes nothing`() {
        for (field in RuleField.entries) {
            val derived = if (field.holdsAddresses) emailText else plainText
            val once = ruleConditionInputType(field, derived)
            assertEquals(once, ruleConditionInputType(field, once), "$field is not idempotent")
        }
    }
}

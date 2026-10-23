package com.cabalmail.android.ui.rules

import android.text.InputType
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.runtime.Composable
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.platform.InterceptPlatformTextInput
import androidx.compose.ui.platform.PlatformTextInputMethodRequest
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import com.cabalmail.kit.models.RuleField

/**
 * How a rule condition's value reaches the IME. A value is a literal
 * substring the engine matches on, so nothing may rewrite it: the keyboard
 * neither capitalizes nor corrects, and it offers no suggestions either.
 *
 * The address headers take the email keyboard, the free-text fields the
 * plain one (#2022, [holdsAddresses]).
 */
fun ruleConditionKeyboardOptions(field: RuleField): KeyboardOptions =
    KeyboardOptions(
        keyboardType = if (field.holdsAddresses) KeyboardType.Email else KeyboardType.Text,
        capitalization = KeyboardCapitalization.None,
        autoCorrectEnabled = false,
    )

/**
 * The `inputType` a condition value edits under.
 *
 * Two levers have already been measured on Gboard 18.5.4 and only one of
 * them works. Clearing `TYPE_TEXT_FLAG_AUTO_CORRECT` (#2023) left Subject
 * and Body at `0x1` and they were rewritten; adding
 * `TYPE_TEXT_FLAG_NO_SUGGESTIONS` took them to `0x80001` and they were
 * rewritten again (#2038). What Gboard does honour is the *variation*: the
 * address fields were the one part of the row never corrected, and what
 * sets them apart is the email variation they take for #2022.
 *
 * So the free-text fields take a variation of their own:
 * `TYPE_TEXT_VARIATION_FILTER`, the one for text that filters a list --
 * which is exactly what a condition value does to the mail stream.
 * Measured verbatim where the rule Name field beside it, at `0x8001`, was
 * corrected 3 of 3 in the same session. The flag rides along for the IMEs
 * that do read it, and the address fields keep their own variation.
 */
fun ruleConditionInputType(
    field: RuleField,
    inputType: Int,
): Int {
    val variation =
        if (field.holdsAddresses) {
            inputType and InputType.TYPE_MASK_VARIATION
        } else {
            InputType.TYPE_TEXT_VARIATION_FILTER
        }
    return (inputType and InputType.TYPE_MASK_VARIATION.inv()) or variation or InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS
}

/**
 * Runs [content] with every text field in it editing under
 * [ruleConditionInputType] for [field].
 *
 * `KeyboardOptions` can ask for neither the variation nor the flag, so the
 * input connection the platform builds is intercepted and the `EditorInfo`
 * Compose filled in is amended in place. Wrap the one field that needs it,
 * never a whole screen: the interception reaches every text field in the
 * subtree.
 */
@OptIn(ExperimentalComposeUiApi::class)
@Composable
fun WithoutImeRewrites(
    field: RuleField,
    content: @Composable () -> Unit,
) {
    InterceptPlatformTextInput(
        interceptor = { request, nextHandler ->
            val amended =
                PlatformTextInputMethodRequest { outAttributes ->
                    val connection = request.createInputConnection(outAttributes)
                    outAttributes.inputType = ruleConditionInputType(field, outAttributes.inputType)
                    connection
                }
            nextHandler.startInputMethod(amended)
        },
        content = content,
    )
}

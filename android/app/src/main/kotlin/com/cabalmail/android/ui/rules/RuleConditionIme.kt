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
 * `inputType` with suggestions refused.
 *
 * `autoCorrectEnabled = false` only clears `TYPE_TEXT_FLAG_AUTO_CORRECT`,
 * which Gboard reads as "this app corrects for itself" rather than "do not
 * correct": Subject and Body values reached it as a bare `0x1` and were
 * rewritten as each word ended, and the editor's auto-save carried the
 * rewrite to the server (#2038). `TYPE_TEXT_FLAG_NO_SUGGESTIONS` is the
 * flag that stops it. Everything else about the type is left as Compose
 * derived it from [ruleConditionKeyboardOptions], so the email variation
 * that already behaved survives.
 */
fun withoutImeSuggestions(inputType: Int): Int = inputType or InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS

/**
 * Runs [content] with every text field in it editing under
 * [withoutImeSuggestions].
 *
 * `KeyboardOptions` has no way to ask for the flag, so the input connection
 * the platform builds is intercepted and the `EditorInfo` Compose filled in
 * is amended in place. Wrap the one field that needs it, never a whole
 * screen: the interception reaches every text field in the subtree.
 */
@OptIn(ExperimentalComposeUiApi::class)
@Composable
fun WithoutImeSuggestions(content: @Composable () -> Unit) {
    InterceptPlatformTextInput(
        interceptor = { request, nextHandler ->
            val amended =
                PlatformTextInputMethodRequest { outAttributes ->
                    val connection = request.createInputConnection(outAttributes)
                    outAttributes.inputType = withoutImeSuggestions(outAttributes.inputType)
                    connection
                }
            nextHandler.startInputMethod(amended)
        },
        content = content,
    )
}

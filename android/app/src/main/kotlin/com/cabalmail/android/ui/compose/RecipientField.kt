package com.cabalmail.android.ui.compose

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.InputChip
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.LocalTextStyle
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import com.cabalmail.android.R

/**
 * Chip-based recipient row (plan §5.1): committed addresses render as
 * removable [InputChip]s, followed by an inline text field. Typing a comma,
 * space, or Enter — or leaving the field — commits the pending text; a
 * rejected commit keeps the text so the user can fix it.
 */
@OptIn(ExperimentalLayoutApi::class)
@Composable
fun RecipientField(
    label: String,
    recipients: List<String>,
    onAdd: (String) -> Boolean,
    onRemove: (String) -> Unit,
    suggestions: List<String>,
    onQueryChange: (String) -> Unit,
    modifier: Modifier = Modifier,
    focusRequester: FocusRequester? = null,
    trailing: @Composable (() -> Unit)? = null,
) {
    var pending by remember { mutableStateOf("") }
    var focused by remember { mutableStateOf(false) }

    fun commit(): Boolean {
        val text = pending.trim().trimEnd(',', ';')
        if (text.isEmpty()) {
            pending = ""
            return true
        }
        return if (onAdd(text)) {
            pending = ""
            onQueryChange("")
            true
        } else {
            false
        }
    }

    Column(modifier = modifier.fillMaxWidth()) {
        Row(
            verticalAlignment = Alignment.Top,
            modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp),
        ) {
            Text(
                text = label,
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.widthIn(min = 48.dp).padding(top = 12.dp),
            )
            FlowRow(
                horizontalArrangement = Arrangement.spacedBy(6.dp),
                verticalArrangement = Arrangement.spacedBy(2.dp),
                modifier = Modifier.weight(1f),
            ) {
                recipients.forEach { address ->
                    InputChip(
                        selected = false,
                        onClick = { onRemove(address) },
                        label = { Text(address, style = MaterialTheme.typography.labelLarge) },
                        trailingIcon = {
                            Icon(
                                Icons.Default.Close,
                                contentDescription = stringResource(R.string.compose_remove_recipient, address),
                            )
                        },
                    )
                }
                val fieldModifier =
                    Modifier
                        .widthIn(min = 96.dp)
                        .padding(vertical = 12.dp)
                        .onFocusChanged { state ->
                            if (focused && !state.isFocused) {
                                commit()
                            }
                            focused = state.isFocused
                        }.let { if (focusRequester != null) it.focusRequester(focusRequester) else it }
                BasicTextField(
                    value = pending,
                    onValueChange = { value ->
                        // Comma / space / semicolon commit what came before.
                        val last = value.lastOrNull()
                        if (last == ',' || last == ' ' || last == ';') {
                            pending = value.dropLast(1)
                            if (!commit()) {
                                pending = value.dropLast(1)
                            }
                        } else {
                            pending = value
                            onQueryChange(value)
                        }
                    },
                    singleLine = true,
                    textStyle = LocalTextStyle.current.copy(color = LocalContentColor.current),
                    cursorBrush = SolidColor(MaterialTheme.colorScheme.primary),
                    keyboardOptions =
                        KeyboardOptions(
                            keyboardType = KeyboardType.Email,
                            capitalization = KeyboardCapitalization.None,
                            imeAction = ImeAction.Next,
                        ),
                    keyboardActions = KeyboardActions(onNext = { commit() }),
                    modifier = fieldModifier,
                )
            }
            trailing?.invoke()
        }
        if (focused && suggestions.isNotEmpty() && pending.isNotBlank()) {
            Surface(
                tonalElevation = 2.dp,
                shape = MaterialTheme.shapes.small,
                modifier = Modifier.padding(horizontal = 16.dp).fillMaxWidth(),
            ) {
                Column {
                    suggestions.forEach { suggestion ->
                        Text(
                            text = suggestion,
                            style = MaterialTheme.typography.bodyMedium,
                            modifier =
                                Modifier
                                    .fillMaxWidth()
                                    .clickable {
                                        if (onAdd(suggestion)) {
                                            pending = ""
                                            onQueryChange("")
                                        }
                                    }.padding(horizontal = 12.dp, vertical = 10.dp),
                        )
                    }
                }
            }
        }
        HorizontalDivider()
    }
}

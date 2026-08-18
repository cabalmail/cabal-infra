package com.cabalmail.android.ui.compose

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExposedDropdownMenuBox
import androidx.compose.material3.ExposedDropdownMenuDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.MenuAnchorType
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import com.cabalmail.android.R
import com.cabalmail.kit.compose.AddressMint

/**
 * "Create new address…" from the From picker (plan §5.1). Minting a fresh
 * relationship-scoped address is the Cabalmail idiom, so this is the
 * picker's primary action rather than a settings detour: local part,
 * subdomain, domain (from the apexes the user may mint on), optional
 * comment, and a Random fill for users who don't want to name it.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun NewAddressSheet(
    domains: List<String>?,
    creating: Boolean,
    error: String?,
    onCreate: (username: String, subdomain: String, tld: String, comment: String) -> Unit,
    onDismiss: () -> Unit,
) {
    var username by rememberSaveable { mutableStateOf("") }
    var subdomain by rememberSaveable { mutableStateOf("") }
    var domain by rememberSaveable { mutableStateOf("") }
    var comment by rememberSaveable { mutableStateOf("") }
    var domainMenuOpen by rememberSaveable { mutableStateOf(false) }

    LaunchedEffect(domains) {
        if (domain.isEmpty()) {
            domains?.firstOrNull()?.let { domain = it }
        }
    }

    val normalizedUser = AddressMint.normalizeLabel(username)
    val normalizedSub = AddressMint.normalizeLabel(subdomain)
    val canSubmit = normalizedUser != null && normalizedSub != null && domain.isNotEmpty() && !creating

    ModalBottomSheet(onDismissRequest = onDismiss) {
        Column(
            verticalArrangement = Arrangement.spacedBy(12.dp),
            modifier =
                Modifier
                    .fillMaxWidth()
                    .verticalScroll(rememberScrollState())
                    .padding(horizontal = 24.dp)
                    .navigationBarsPadding()
                    .imePadding(),
        ) {
            Text(stringResource(R.string.new_address_title), style = MaterialTheme.typography.titleLarge)
            OutlinedTextField(
                value = username,
                onValueChange = { username = it },
                label = { Text(stringResource(R.string.new_address_username)) },
                singleLine = true,
                keyboardOptions =
                    KeyboardOptions(keyboardType = KeyboardType.Ascii, capitalization = KeyboardCapitalization.None),
                modifier = Modifier.fillMaxWidth(),
            )
            OutlinedTextField(
                value = subdomain,
                onValueChange = { subdomain = it },
                label = { Text(stringResource(R.string.new_address_subdomain)) },
                singleLine = true,
                keyboardOptions =
                    KeyboardOptions(keyboardType = KeyboardType.Ascii, capitalization = KeyboardCapitalization.None),
                modifier = Modifier.fillMaxWidth(),
            )
            ExposedDropdownMenuBox(
                expanded = domainMenuOpen,
                onExpandedChange = { domainMenuOpen = it && !domains.isNullOrEmpty() },
            ) {
                OutlinedTextField(
                    value =
                        when {
                            domains == null -> stringResource(R.string.new_address_loading_domains)
                            domains.isEmpty() -> stringResource(R.string.new_address_no_domains)
                            else -> domain
                        },
                    onValueChange = {},
                    readOnly = true,
                    label = { Text(stringResource(R.string.new_address_domain)) },
                    trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(expanded = domainMenuOpen) },
                    modifier = Modifier.fillMaxWidth().menuAnchor(MenuAnchorType.PrimaryNotEditable),
                )
                ExposedDropdownMenu(
                    expanded = domainMenuOpen,
                    onDismissRequest = { domainMenuOpen = false },
                ) {
                    domains.orEmpty().forEach { candidate ->
                        DropdownMenuItem(
                            text = { Text(candidate) },
                            onClick = {
                                domain = candidate
                                domainMenuOpen = false
                            },
                        )
                    }
                }
            }
            OutlinedTextField(
                value = comment,
                onValueChange = { comment = it },
                label = { Text(stringResource(R.string.new_address_comment)) },
                singleLine = true,
                modifier = Modifier.fillMaxWidth(),
            )
            if (normalizedUser != null && normalizedSub != null && domain.isNotEmpty()) {
                Text(
                    text = stringResource(R.string.new_address_preview, normalizedUser, normalizedSub, domain),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            error?.let {
                Text(it, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall)
            }
            Row(
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.fillMaxWidth(),
            ) {
                TextButton(
                    onClick = {
                        username = AddressMint.randomLabel()
                        subdomain = AddressMint.randomLabel()
                    },
                ) {
                    Text(stringResource(R.string.new_address_random))
                }
                Spacer(Modifier.weight(1f))
                TextButton(onClick = onDismiss) { Text(stringResource(R.string.cancel)) }
                Button(
                    onClick = {
                        if (normalizedUser != null && normalizedSub != null) {
                            onCreate(normalizedUser, normalizedSub, domain, comment.trim())
                        }
                    },
                    enabled = canSubmit,
                ) {
                    if (creating) {
                        CircularProgressIndicator(strokeWidth = 2.dp, modifier = Modifier.height(18.dp))
                    } else {
                        Text(stringResource(R.string.new_address_create))
                    }
                }
            }
            Spacer(Modifier.height(16.dp))
        }
    }
}

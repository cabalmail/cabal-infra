package com.cabalmail.android.ui.settings

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.autofill.ContentType
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentType
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.lifecycle.viewmodel.compose.viewModel
import com.cabalmail.android.AppContainer
import com.cabalmail.android.R
import com.cabalmail.kit.auth.RecoveryEmailPrompt

private val fieldWidth = Modifier.widthIn(max = 480.dp).fillMaxWidth()

/**
 * Settings › Account › Recovery email (auth parity B4): the one place to
 * add an address after sign-up, which a phone-only account (plan D5) is
 * never asked for.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun RecoveryEmailScreen(
    viewModel: RecoveryEmailViewModel,
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val state by viewModel.state.collectAsState()
    Scaffold(
        modifier = modifier.fillMaxSize(),
        topBar = {
            TopAppBar(
                title = { Text(stringResource(R.string.settings_recovery_email)) },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = stringResource(R.string.back))
                    }
                },
            )
        },
    ) { innerPadding ->
        RecoveryEmailContent(state, viewModel, Modifier.padding(innerPadding))
    }
}

/**
 * The full-screen dialog the check after an interactive sign-in raises
 * (auth parity B4; `docs/auth.md`, "After sign-in"). The user can skip
 * it; it never blocks the sign-in that raised it.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun RecoveryEmailPromptDialog(
    container: AppContainer,
    prompt: RecoveryEmailPrompt,
    onDismiss: () -> Unit,
) {
    val viewModel: RecoveryEmailViewModel =
        viewModel(key = "recovery-prompt-$prompt", factory = RecoveryEmailViewModel.factory(container, prompt))
    val state by viewModel.state.collectAsState()
    Dialog(onDismissRequest = onDismiss, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Scaffold(
            modifier = Modifier.fillMaxSize(),
            topBar = {
                TopAppBar(
                    title = {
                        Text(
                            if (prompt is RecoveryEmailPrompt.Verify) "Verify your email" else "Add a recovery email",
                        )
                    },
                    actions = {
                        TextButton(onClick = onDismiss) { Text(if (state.isVerified) "Done" else "Skip for now") }
                    },
                )
            },
        ) { innerPadding ->
            Column(Modifier.padding(innerPadding)) {
                Text(
                    text =
                        if (prompt is RecoveryEmailPrompt.Verify) {
                            "Verify ${prompt.address} so it can be used to recover your account."
                        } else {
                            "Add an address outside Cabalmail so you can get back in if you forget your password. " +
                                "You can also do this later in Settings › Account."
                        },
                    style = MaterialTheme.typography.bodyMedium,
                    modifier = Modifier.padding(horizontal = 24.dp, vertical = 8.dp),
                )
                RecoveryEmailContent(state, viewModel)
            }
        }
    }
}

@Composable
private fun RecoveryEmailContent(
    state: RecoveryEmailUiState,
    viewModel: RecoveryEmailViewModel,
    modifier: Modifier = Modifier,
) {
    Column(
        modifier =
            modifier
                .fillMaxSize()
                .imePadding()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 24.dp, vertical = 16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        when (val step = state.step) {
            RecoveryEmailStep.Loading -> CircularProgressIndicator()
            is RecoveryEmailStep.Failed -> {
                ErrorLine(step.message)
                Button(onClick = viewModel::load) { Text("Try again") }
            }
            RecoveryEmailStep.Showing -> {
                Text(state.statusText, style = MaterialTheme.typography.bodyLarge, modifier = fieldWidth)
                if (state.address != null && !state.isVerified) {
                    Button(onClick = viewModel::sendCode, enabled = !state.busy) { Text("Verify address") }
                }
                TextButton(onClick = viewModel::startEditing, enabled = !state.busy) {
                    Text(if (state.address == null) "Add recovery email" else "Change address")
                }
            }
            RecoveryEmailStep.Editing -> {
                OutlinedTextField(
                    value = state.draft,
                    onValueChange = viewModel::editDraft,
                    label = { Text(if (state.address == null) "Recovery email" else "New recovery email") },
                    supportingText = { Text(state.editingHelp) },
                    keyboardOptions =
                        KeyboardOptions(
                            keyboardType = KeyboardType.Email,
                            autoCorrectEnabled = false,
                            imeAction = ImeAction.Done,
                        ),
                    singleLine = true,
                    enabled = !state.busy,
                    modifier = fieldWidth.semantics { contentType = ContentType.EmailAddress },
                )
                Button(onClick = viewModel::save, enabled = state.canSave) { Text("Save and send code") }
                TextButton(onClick = viewModel::cancel, enabled = !state.busy) { Text("Cancel") }
            }
            RecoveryEmailStep.Verifying -> {
                Text(
                    "Enter the code we sent to ${state.address ?: "your email"}.",
                    style = MaterialTheme.typography.bodyMedium,
                )
                OutlinedTextField(
                    value = state.code,
                    onValueChange = viewModel::editCode,
                    label = { Text("Verification code") },
                    keyboardOptions =
                        KeyboardOptions(
                            keyboardType = KeyboardType.NumberPassword,
                            imeAction = ImeAction.Done,
                        ),
                    singleLine = true,
                    enabled = !state.busy,
                    modifier = fieldWidth.semantics { contentType = ContentType.SmsOtpCode },
                )
                Button(onClick = viewModel::verify, enabled = state.canVerify) { Text("Verify") }
                TextButton(onClick = viewModel::sendCode, enabled = !state.busy) { Text("Send a new code") }
                TextButton(onClick = viewModel::cancel, enabled = !state.busy) { Text("Cancel") }
            }
        }
        if (state.busy) {
            CircularProgressIndicator()
        }
        state.notice?.let { Text(it, style = MaterialTheme.typography.bodyMedium, modifier = fieldWidth) }
        state.error?.let { ErrorLine(it) }
    }
}

@Composable
private fun ErrorLine(message: String) {
    Text(
        text = message,
        style = MaterialTheme.typography.bodyMedium,
        color = MaterialTheme.colorScheme.error,
        modifier = fieldWidth,
    )
}

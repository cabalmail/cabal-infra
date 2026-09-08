package com.cabalmail.android.ui.auth

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.autofill.ContentType
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentType
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import com.cabalmail.android.R
import com.cabalmail.kit.auth.MfaMethod

/**
 * Control-domain/username/password sign-in with the TOTP/SMS challenge
 * leg. Capture is three-field like the Apple client's: the server (the
 * control domain, remembered across launches), then the account. Sign-up,
 * confirmation, and forgot-password flows arrive with the full auth UI
 * work; this is the Phase 3 surface that makes the kit auth stack usable
 * on-device.
 */
@Composable
fun SignInScreen(
    state: SignInUiState,
    onSignIn: (controlDomain: String, username: String, password: String) -> Unit,
    onSubmitMfaCode: (code: String) -> Unit,
    modifier: Modifier = Modifier,
) {
    var controlDomain by rememberSaveable { mutableStateOf("") }
    var username by rememberSaveable { mutableStateOf("") }
    var password by rememberSaveable { mutableStateOf("") }
    var mfaCode by rememberSaveable { mutableStateOf("") }

    // Prefill the server once it is known, but never over something the
    // user has already typed (the read is async and may land mid-edit).
    LaunchedEffect(state.rememberedControlDomain) {
        if (controlDomain.isEmpty()) {
            controlDomain = state.rememberedControlDomain.orEmpty()
        }
    }

    Scaffold(modifier = modifier.fillMaxSize()) { innerPadding ->
        Column(
            modifier =
                Modifier
                    .padding(innerPadding)
                    .fillMaxSize()
                    // The IME can be taller than the form on a landscape
                    // tablet, so give back the space it takes and let what
                    // is left scroll. `verticalScroll` keeps the incoming
                    // minimum height, so a form that still fits stays
                    // centred exactly as before.
                    .imePadding()
                    .verticalScroll(rememberScrollState())
                    .padding(horizontal = 32.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp, Alignment.CenterVertically),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Text(
                text = stringResource(R.string.app_name),
                style = MaterialTheme.typography.headlineLarge,
                color = MaterialTheme.colorScheme.primary,
            )

            when (state.phase) {
                is AuthPhase.MfaRequired -> {
                    Text(
                        text =
                            stringResource(
                                when (state.phase.method) {
                                    MfaMethod.TOTP -> R.string.mfa_prompt_totp
                                    MfaMethod.SMS -> R.string.mfa_prompt_sms
                                },
                            ),
                        style = MaterialTheme.typography.bodyMedium,
                    )
                    val canSubmitCode = canSubmitMfaCode(state.busy, mfaCode)
                    OutlinedTextField(
                        value = mfaCode,
                        onValueChange = { mfaCode = it },
                        label = { Text(stringResource(R.string.mfa_code_label)) },
                        keyboardOptions =
                            KeyboardOptions(
                                keyboardType = KeyboardType.NumberPassword,
                                imeAction = ImeAction.Done,
                            ),
                        // The keyboard's own action key submits, on the same
                        // condition as the button it stands in for.
                        keyboardActions = KeyboardActions(onDone = { if (canSubmitCode) onSubmitMfaCode(mfaCode) }),
                        singleLine = true,
                        enabled = !state.busy,
                        modifier =
                            Modifier
                                .widthIn(max = 400.dp)
                                .fillMaxWidth()
                                // The autofill hint password managers key on
                                // to offer the saved login's one-time code.
                                // SmsOtpCode is the only OTP content type the
                                // framework defines; it covers TOTP too.
                                .semantics { contentType = ContentType.SmsOtpCode },
                    )
                    Button(
                        onClick = { onSubmitMfaCode(mfaCode) },
                        enabled = canSubmitCode,
                    ) {
                        Text(stringResource(R.string.mfa_submit))
                    }
                }

                else -> {
                    OutlinedTextField(
                        value = controlDomain,
                        onValueChange = { controlDomain = it },
                        label = { Text(stringResource(R.string.control_domain_label)) },
                        placeholder = { Text(stringResource(R.string.control_domain_hint)) },
                        // Always visible, unlike the placeholder: the admin
                        // host is the one domain a user has no reason to know
                        // by heart (mail lives on other domains), and nothing
                        // else on this screen says what shape it takes.
                        supportingText = { Text(stringResource(R.string.control_domain_supporting)) },
                        keyboardOptions =
                            KeyboardOptions(
                                keyboardType = KeyboardType.Uri,
                                capitalization = KeyboardCapitalization.None,
                                autoCorrectEnabled = false,
                                imeAction = ImeAction.Next,
                            ),
                        singleLine = true,
                        enabled = !state.busy,
                        modifier = Modifier.widthIn(max = 400.dp).fillMaxWidth(),
                    )
                    OutlinedTextField(
                        value = username,
                        onValueChange = { username = it },
                        label = { Text(stringResource(R.string.username_label)) },
                        keyboardOptions = KeyboardOptions(imeAction = ImeAction.Next),
                        singleLine = true,
                        enabled = !state.busy,
                        modifier =
                            Modifier
                                .widthIn(max = 400.dp)
                                .fillMaxWidth()
                                .semantics { contentType = ContentType.Username },
                    )
                    val canSignIn = canSubmitSignIn(state.busy, controlDomain, username, password)
                    OutlinedTextField(
                        value = password,
                        onValueChange = { password = it },
                        label = { Text(stringResource(R.string.password_label)) },
                        visualTransformation = PasswordVisualTransformation(),
                        keyboardOptions =
                            KeyboardOptions(
                                keyboardType = KeyboardType.Password,
                                imeAction = ImeAction.Done,
                            ),
                        keyboardActions =
                            KeyboardActions(
                                onDone = { if (canSignIn) onSignIn(controlDomain, username, password) },
                            ),
                        singleLine = true,
                        enabled = !state.busy,
                        modifier =
                            Modifier
                                .widthIn(max = 400.dp)
                                .fillMaxWidth()
                                .semantics { contentType = ContentType.Password },
                    )
                    Button(
                        onClick = { onSignIn(controlDomain, username, password) },
                        enabled = canSignIn,
                    ) {
                        Text(stringResource(R.string.sign_in))
                    }
                }
            }

            if (state.busy) {
                CircularProgressIndicator()
            }
            state.error?.let { message ->
                Text(
                    text = message,
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.error,
                )
            }
        }
    }
}

/**
 * Whether the sign-in form can be submitted. The `Sign In` button and the
 * keyboard's own action key both ask this, so the IME can never submit a
 * form the button is refusing (#1477).
 */
internal fun canSubmitSignIn(
    busy: Boolean,
    controlDomain: String,
    username: String,
    password: String,
): Boolean = !busy && controlDomain.isNotBlank() && username.isNotBlank() && password.isNotBlank()

/** The same rule for the MFA challenge's `Verify` button and action key. */
internal fun canSubmitMfaCode(
    busy: Boolean,
    code: String,
): Boolean = !busy && code.isNotBlank()

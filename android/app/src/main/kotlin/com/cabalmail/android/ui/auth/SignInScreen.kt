package com.cabalmail.android.ui.auth

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import com.cabalmail.android.R
import com.cabalmail.kit.auth.MfaMethod

/**
 * Username/password sign-in with the TOTP/SMS challenge leg. Sign-up,
 * confirmation, and forgot-password flows arrive with the full auth UI
 * work; this is the Phase 3 surface that makes the kit auth stack usable
 * on-device.
 */
@Composable
fun SignInScreen(
    state: SignInUiState,
    onSignIn: (username: String, password: String) -> Unit,
    onSubmitMfaCode: (code: String) -> Unit,
    modifier: Modifier = Modifier,
) {
    var username by rememberSaveable { mutableStateOf("") }
    var password by rememberSaveable { mutableStateOf("") }
    var mfaCode by rememberSaveable { mutableStateOf("") }

    Scaffold(modifier = modifier.fillMaxSize()) { innerPadding ->
        Column(
            modifier =
                Modifier
                    .padding(innerPadding)
                    .fillMaxSize()
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
                    OutlinedTextField(
                        value = mfaCode,
                        onValueChange = { mfaCode = it },
                        label = { Text(stringResource(R.string.mfa_code_label)) },
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.NumberPassword),
                        singleLine = true,
                        enabled = !state.busy,
                        modifier = Modifier.widthIn(max = 400.dp).fillMaxWidth(),
                    )
                    Button(
                        onClick = { onSubmitMfaCode(mfaCode) },
                        enabled = !state.busy && mfaCode.isNotBlank(),
                    ) {
                        Text(stringResource(R.string.mfa_submit))
                    }
                }

                else -> {
                    OutlinedTextField(
                        value = username,
                        onValueChange = { username = it },
                        label = { Text(stringResource(R.string.username_label)) },
                        singleLine = true,
                        enabled = !state.busy,
                        modifier = Modifier.widthIn(max = 400.dp).fillMaxWidth(),
                    )
                    OutlinedTextField(
                        value = password,
                        onValueChange = { password = it },
                        label = { Text(stringResource(R.string.password_label)) },
                        visualTransformation = PasswordVisualTransformation(),
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password),
                        singleLine = true,
                        enabled = !state.busy,
                        modifier = Modifier.widthIn(max = 400.dp).fillMaxWidth(),
                    )
                    Button(
                        onClick = { onSignIn(username, password) },
                        enabled = !state.busy && username.isNotBlank() && password.isNotBlank(),
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

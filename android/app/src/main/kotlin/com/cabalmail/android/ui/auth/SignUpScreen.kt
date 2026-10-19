package com.cabalmail.android.ui.auth

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.Checkbox
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.autofill.ContentType
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentType
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.LinkAnnotation
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.withLink
import androidx.compose.ui.unit.dp
import com.cabalmail.android.R
import com.cabalmail.kit.auth.CodeDelivery

private val fieldWidth = Modifier.widthIn(max = 400.dp).fillMaxWidth()

/**
 * The sign-up steps (auth parity B3), shown in place of the sign-in screen
 * and laid out like it: the form, the confirmation code, and the
 * account-created result. [SignUpViewModel] holds the flow. [onFinish]
 * returns to sign-in, with the new account's username once there is one;
 * the system back gesture does the same.
 */
@Composable
fun SignUpScreen(
    viewModel: SignUpViewModel,
    onFinish: (createdUsername: String?) -> Unit,
    modifier: Modifier = Modifier,
) {
    val state by viewModel.state.collectAsState()
    val finish = { onFinish((state.step as? SignUpStep.Created)?.username) }
    BackHandler(enabled = !state.busy, onBack = finish)

    Scaffold(modifier = modifier.fillMaxSize()) { innerPadding ->
        Column(
            modifier =
                Modifier
                    .padding(innerPadding)
                    .fillMaxSize()
                    .imePadding()
                    .verticalScroll(rememberScrollState())
                    .padding(horizontal = 32.dp, vertical = 24.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp, Alignment.CenterVertically),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Text(
                text = stringResource(R.string.app_name),
                style = MaterialTheme.typography.headlineLarge,
                color = MaterialTheme.colorScheme.primary,
            )
            when (val step = state.step) {
                SignUpStep.Loading -> LoadingStep(state.controlDomain, onBack = finish)
                is SignUpStep.Unavailable -> UnavailableStep(step.message, onRetry = viewModel::load, onBack = finish)
                SignUpStep.Form ->
                    FormStep(
                        state,
                        onEdit = viewModel::edit,
                        onSubmit = viewModel::submit,
                        onBack = finish,
                    )
                is SignUpStep.Confirm ->
                    CodeStep(
                        state = state,
                        delivery = step.delivery,
                        onEdit = viewModel::edit,
                        onConfirm = viewModel::confirm,
                        onResend = viewModel::resend,
                        onBack = finish,
                    )
                is SignUpStep.Created -> CreatedStep(step, onBack = finish)
            }
            if (state.busy) {
                CircularProgressIndicator()
            }
            state.error?.let { ErrorText(it) }
        }
    }
}

@Composable
private fun LoadingStep(
    controlDomain: String,
    onBack: () -> Unit,
) {
    CircularProgressIndicator()
    Text("Checking $controlDomain…", style = MaterialTheme.typography.bodyMedium)
    TextButton(onClick = onBack) { Text("Back to sign in") }
}

@Composable
private fun UnavailableStep(
    message: String,
    onRetry: () -> Unit,
    onBack: () -> Unit,
) {
    ErrorText(message)
    Button(onClick = onRetry) { Text("Try again") }
    TextButton(onClick = onBack) { Text("Back to sign in") }
}

/**
 * The form: username, the contacts the deployment asks for (plan D5), the
 * invitation code when one is required, the password, and SMS consent when
 * SMS is on.
 */
@Composable
private fun FormStep(
    state: SignUpUiState,
    onEdit: ((SignUpForm) -> SignUpForm) -> Unit,
    onSubmit: () -> Unit,
    onBack: () -> Unit,
) {
    val form = state.form
    val policy = state.policy
    val enabled = !state.busy
    Text("New account on ${state.controlDomain}", style = MaterialTheme.typography.titleMedium)
    OutlinedTextField(
        value = form.username,
        onValueChange = { value -> onEdit { it.copy(username = value) } },
        label = { Text("Username") },
        supportingText = { Text("3 to 32 lowercase letters, numbers and hyphens, with at least one letter.") },
        keyboardOptions =
            KeyboardOptions(
                capitalization = KeyboardCapitalization.None,
                autoCorrectEnabled = false,
                imeAction = ImeAction.Next,
            ),
        singleLine = true,
        enabled = enabled,
        modifier = fieldWidth.semantics { contentType = ContentType.NewUsername },
    )
    if (policy.smsEnabled) {
        OutlinedTextField(
            value = form.phone,
            onValueChange = { value -> onEdit { it.copy(phone = value) } },
            label = { Text("Phone number") },
            supportingText = {
                Text(
                    "We text a code here to verify the account. Include the country code, starting with +.",
                )
            },
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Phone, imeAction = ImeAction.Next),
            singleLine = true,
            enabled = enabled,
            modifier = fieldWidth.semantics { contentType = ContentType.PhoneNumber },
        )
    }
    OutlinedTextField(
        value = form.email,
        onValueChange = { value -> onEdit { it.copy(email = value) } },
        label = { Text(if (policy.smsEnabled) "Recovery email (optional)" else "Recovery email") },
        supportingText = {
            Text(
                if (policy.smsEnabled) {
                    "An address outside Cabalmail gets you back in if you lose your phone."
                } else {
                    "Use an address outside Cabalmail. It's how you get back in if you forget your password."
                },
            )
        },
        keyboardOptions =
            KeyboardOptions(
                keyboardType = KeyboardType.Email,
                autoCorrectEnabled = false,
                imeAction = ImeAction.Next,
            ),
        singleLine = true,
        enabled = enabled,
        modifier = fieldWidth.semantics { contentType = ContentType.EmailAddress },
    )
    if (policy.invitationRequired) {
        OutlinedTextField(
            value = form.invitationCode,
            onValueChange = { value -> onEdit { it.copy(invitationCode = value) } },
            label = { Text("Invitation code") },
            supportingText = { Text("Sign-up is by invitation. Enter the code you were given.") },
            keyboardOptions = KeyboardOptions(autoCorrectEnabled = false, imeAction = ImeAction.Next),
            singleLine = true,
            enabled = enabled,
            modifier = fieldWidth,
        )
    }
    OutlinedTextField(
        value = form.password,
        onValueChange = { value -> onEdit { it.copy(password = value) } },
        label = { Text("Password") },
        supportingText = {
            Text(
                "At least ${SignUpRules.MIN_PASSWORD_LENGTH} characters, mixing upper- and lowercase letters, " +
                    "numbers and symbols.",
            )
        },
        visualTransformation = PasswordVisualTransformation(),
        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password, imeAction = ImeAction.Next),
        singleLine = true,
        enabled = enabled,
        modifier = fieldWidth.semantics { contentType = ContentType.NewPassword },
    )
    OutlinedTextField(
        value = form.confirmPassword,
        onValueChange = { value -> onEdit { it.copy(confirmPassword = value) } },
        label = { Text("Confirm password") },
        visualTransformation = PasswordVisualTransformation(),
        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password, imeAction = ImeAction.Done),
        singleLine = true,
        enabled = enabled,
        modifier = fieldWidth.semantics { contentType = ContentType.NewPassword },
    )
    if (policy.smsEnabled) {
        // The whole row toggles, as the webmail's label does its checkbox;
        // unchecked until the user checks it.
        Row(
            modifier =
                fieldWidth.toggleable(
                    value = form.smsConsent,
                    enabled = enabled,
                    role = Role.Checkbox,
                    onValueChange = { checked -> onEdit { it.copy(smsConsent = checked) } },
                ),
            verticalAlignment = Alignment.Top,
        ) {
            Checkbox(checked = form.smsConsent, onCheckedChange = null, enabled = enabled)
            Text(
                text = state.consentText,
                style = MaterialTheme.typography.bodySmall,
                modifier = Modifier.padding(start = 8.dp),
            )
        }
    }
    Button(onClick = onSubmit, enabled = state.canSubmit) { Text("Create Account") }
    TextButton(onClick = onBack, enabled = enabled) { Text("Back to sign in") }
    state.missingRequirement?.let { Text(it, style = MaterialTheme.typography.bodySmall) }
    Text(termsText(state), style = MaterialTheme.typography.bodySmall, modifier = fieldWidth)
}

/** The webmail's line under its form, with the same two links. */
private fun termsText(state: SignUpUiState): AnnotatedString =
    buildAnnotatedString {
        append("By creating an account you agree to the ")
        link(state.termsUrl, "Terms")
        append(" and ")
        link(state.privacyUrl, "Privacy Policy")
        append(".")
    }

private fun AnnotatedString.Builder.link(
    url: String?,
    text: String,
) {
    if (url == null) {
        append(text)
    } else {
        withLink(LinkAnnotation.Url(url)) { append(text) }
    }
}

@Composable
private fun CodeStep(
    state: SignUpUiState,
    delivery: CodeDelivery,
    onEdit: ((SignUpForm) -> SignUpForm) -> Unit,
    onConfirm: () -> Unit,
    onResend: () -> Unit,
    onBack: () -> Unit,
) {
    Text("Verify your account", style = MaterialTheme.typography.titleMedium)
    Text("Enter the code we sent to ${SignUpRules.describe(delivery)}.", style = MaterialTheme.typography.bodyMedium)
    OutlinedTextField(
        value = state.form.code,
        onValueChange = { value -> onEdit { it.copy(code = value) } },
        label = { Text("Verification code") },
        supportingText = { Text("If you leave now, an administrator can still confirm the account.") },
        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.NumberPassword, imeAction = ImeAction.Done),
        singleLine = true,
        enabled = !state.busy,
        modifier = fieldWidth.semantics { contentType = ContentType.SmsOtpCode },
    )
    Button(onClick = onConfirm, enabled = state.canConfirm) { Text("Verify") }
    TextButton(onClick = onResend, enabled = state.canResend && !state.busy) { Text("Send a new code") }
    TextButton(onClick = onBack, enabled = !state.busy) { Text("Back to sign in") }
    state.notice?.let { Text(it, style = MaterialTheme.typography.bodyMedium) }
}

/**
 * "Pending admin approval" in practice is the domain grant: the account
 * can sign in now and creates addresses once an administrator grants it
 * mail domains (`docs/auth.md`, "Sign-up").
 */
@Composable
private fun CreatedStep(
    step: SignUpStep.Created,
    onBack: () -> Unit,
) {
    val verified =
        when (step.verifiedBy) {
            CodeDelivery.Medium.PHONE -> "Your phone number is verified. "
            CodeDelivery.Medium.EMAIL -> "Your email address is verified. "
            null -> ""
        }
    Text("Account created", style = MaterialTheme.typography.titleMedium)
    Text(
        verified + "An administrator still has to approve it before you can create addresses. You can sign in now.",
        style = MaterialTheme.typography.bodyMedium,
        modifier = fieldWidth,
    )
    Button(onClick = onBack) { Text("Back to sign in") }
}

@Composable
private fun ErrorText(message: String) {
    Text(
        text = message,
        style = MaterialTheme.typography.bodyMedium,
        color = MaterialTheme.colorScheme.error,
        modifier = fieldWidth,
    )
}

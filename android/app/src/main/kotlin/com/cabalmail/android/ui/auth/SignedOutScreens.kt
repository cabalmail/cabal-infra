package com.cabalmail.android.ui.auth

import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.saveable.rememberSaveableStateHolder
import androidx.compose.runtime.setValue
import androidx.lifecycle.viewmodel.compose.viewModel
import com.cabalmail.android.AppContainer

/**
 * What a signed-out user sees: the sign-in screen, or the sign-up flow
 * (auth parity B3) its Create account opens against the typed server.
 *
 * The sign-in screen's typed server and username survive a trip to
 * sign-up, since its state is held while it is off screen. Each Create
 * account starts a fresh sign-up flow, and a rotation keeps the one in
 * progress.
 */
@Composable
fun SignedOutScreens(
    container: AppContainer,
    state: SignInUiState,
    onSignIn: (controlDomain: String, username: String, password: String) -> Unit,
    onSubmitMfaCode: (code: String) -> Unit,
) {
    var signUpDomain by rememberSaveable { mutableStateOf<String?>(null) }
    var signUpSession by rememberSaveable { mutableIntStateOf(0) }
    var createdUsername by rememberSaveable { mutableStateOf<String?>(null) }
    val heldState = rememberSaveableStateHolder()

    val domain = signUpDomain
    if (domain == null) {
        heldState.SaveableStateProvider("sign-in") {
            SignInScreen(
                state = state,
                onSignIn = onSignIn,
                onSubmitMfaCode = onSubmitMfaCode,
                onCreateAccount = {
                    signUpSession += 1
                    signUpDomain = it
                },
                createdUsername = createdUsername,
                onCreatedUsernameApplied = { createdUsername = null },
            )
        }
    } else {
        val signUp: SignUpViewModel =
            viewModel(key = "sign-up-$signUpSession", factory = SignUpViewModel.factory(container, domain))
        SignUpScreen(
            viewModel = signUp,
            onFinish = { username ->
                createdUsername = username
                signUpDomain = null
            },
        )
    }
}

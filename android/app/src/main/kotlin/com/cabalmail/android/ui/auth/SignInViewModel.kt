package com.cabalmail.android.ui.auth

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import com.cabalmail.android.AppContainer
import com.cabalmail.android.userMessage
import com.cabalmail.kit.auth.MfaMethod
import com.cabalmail.kit.auth.SignInResult
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

/** Where the sign-in flow currently stands. */
sealed interface AuthPhase {
    data object SignedOut : AuthPhase

    data class MfaRequired(
        val method: MfaMethod,
    ) : AuthPhase

    data class SignedIn(
        val username: String,
    ) : AuthPhase
}

data class SignInUiState(
    val phase: AuthPhase = AuthPhase.SignedOut,
    val busy: Boolean = false,
    val error: String? = null,
)

class SignInViewModel(
    private val container: AppContainer,
) : ViewModel() {
    private val mutableState =
        MutableStateFlow(
            // A stored session resumes without re-authentication; token
            // refresh happens lazily on the first API call.
            container.tokenStore.readTokens()?.let { _ ->
                SignInUiState(phase = AuthPhase.SignedIn(container.tokenStore.readUsername().orEmpty()))
            } ?: SignInUiState(),
        )
    val state: StateFlow<SignInUiState> = mutableState.asStateFlow()

    init {
        // A refreshed token the API still rejects means the session is
        // over: drop to the sign-in screen with a reason (plan §7.5).
        viewModelScope.launch {
            container.authExpired.collect {
                runCatching { container.requireAuth().signOut() }
                mutableState.update {
                    SignInUiState(phase = AuthPhase.SignedOut, error = "Your session expired — sign in again")
                }
            }
        }
    }

    fun signIn(
        username: String,
        password: String,
    ) {
        runAuthAction {
            when (val result = container.requireAuth().signIn(username.trim(), password)) {
                is SignInResult.SignedIn -> AuthPhase.SignedIn(username.trim())
                is SignInResult.MfaCodeRequired -> AuthPhase.MfaRequired(result.method)
            }
        }
    }

    fun submitMfaCode(code: String) {
        runAuthAction {
            val auth = container.requireAuth()
            auth.submitMfaCode(code.trim())
            AuthPhase.SignedIn(auth.currentUsername().orEmpty())
        }
    }

    fun signOut() {
        runAuthAction {
            container.requireAuth().signOut()
            AuthPhase.SignedOut
        }
    }

    private fun runAuthAction(action: suspend () -> AuthPhase) {
        viewModelScope.launch {
            mutableState.update { it.copy(busy = true, error = null) }
            try {
                val phase = action()
                mutableState.update { SignInUiState(phase = phase) }
            } catch (exception: Exception) {
                mutableState.update {
                    it.copy(busy = false, error = userMessage(exception, "Something went wrong"))
                }
            }
        }
    }

    companion object {
        fun factory(container: AppContainer): ViewModelProvider.Factory =
            viewModelFactory {
                initializer { SignInViewModel(container) }
            }
    }
}

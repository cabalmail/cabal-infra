package com.cabalmail.android.ui.auth

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import com.cabalmail.android.AppContainer
import com.cabalmail.android.userMessage
import com.cabalmail.kit.auth.AuthService
import com.cabalmail.kit.auth.MfaMethod
import com.cabalmail.kit.auth.SignInResult
import com.cabalmail.kit.config.ConfigException
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import java.io.IOException

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
    /**
     * The control domain to prefill on the form: the one this install last
     * fetched a config from (kept across sign-out, like the Apple client's
     * remembered "Control domain"), else a developer build's default, else
     * null while it is still being read or when there is nothing to offer.
     */
    val rememberedControlDomain: String? = null,
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
        viewModelScope.launch {
            val remembered = container.configService.rememberedControlDomain()
            mutableState.update { it.copy(rememberedControlDomain = remembered) }
            // Stored tokens with no server to use them against (an install
            // that signed in when the domain was baked into the build, now
            // running a build without one) cannot resume: clear them and
            // ask for the server.
            if (remembered == null && mutableState.value.phase is AuthPhase.SignedIn) {
                container.tokenStore.clear()
                mutableState.update { it.copy(phase = AuthPhase.SignedOut) }
            }
        }
        // A refreshed token the API still rejects means the session is
        // over: drop to the sign-in screen with a reason (plan §7.5).
        viewModelScope.launch {
            container.authExpired.collect {
                runCatching { container.requireAuth().signOut() }
                mutableState.update {
                    it.copy(
                        phase = AuthPhase.SignedOut,
                        busy = false,
                        error = "Your session expired — sign in again",
                    )
                }
            }
        }
    }

    fun signIn(
        controlDomain: String,
        username: String,
        password: String,
    ) {
        runAuthAction {
            val auth = authFor(controlDomain)
            when (val result = auth.signIn(username.trim(), password)) {
                is SignInResult.SignedIn -> AuthPhase.SignedIn(username.trim())
                is SignInResult.MfaCodeRequired -> AuthPhase.MfaRequired(result.method)
            }
        }
    }

    /**
     * Points the container at [controlDomain] and returns its auth service.
     * A transport failure here is almost always a mistyped server rather
     * than the offline case the generic message describes, so it is
     * reworded before [userMessage] sees it.
     */
    private suspend fun authFor(controlDomain: String): AuthService {
        val domain = controlDomain.trim()
        return try {
            container.requireAuth(domain)
        } catch (exception: IOException) {
            throw ConfigException("Couldn't reach $domain — check the control domain and your connection", exception)
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
                val activeDomain = container.configService.controlDomain.value
                mutableState.update {
                    SignInUiState(
                        phase = phase,
                        rememberedControlDomain = activeDomain ?: it.rememberedControlDomain,
                    )
                }
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

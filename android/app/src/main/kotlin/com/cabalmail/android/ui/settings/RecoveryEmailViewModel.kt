package com.cabalmail.android.ui.settings

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import com.cabalmail.android.AppContainer
import com.cabalmail.android.ui.auth.SignUpRules
import com.cabalmail.kit.auth.AuthService
import com.cabalmail.kit.auth.RecoveryContacts
import com.cabalmail.kit.auth.RecoveryEmailPrompt
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

/** Where the recovery-email screen stands. */
sealed interface RecoveryEmailStep {
    data object Loading : RecoveryEmailStep

    data class Failed(
        val message: String,
    ) : RecoveryEmailStep

    /** The address, or its absence, and what can be done with it. */
    data object Showing : RecoveryEmailStep

    data object Editing : RecoveryEmailStep

    /** A code is on its way to the address; the user enters it. */
    data object Verifying : RecoveryEmailStep
}

data class RecoveryEmailUiState(
    val step: RecoveryEmailStep = RecoveryEmailStep.Loading,
    val smsEnabled: Boolean = true,
    val contacts: RecoveryContacts? = null,
    val draft: String = "",
    val code: String = "",
    val busy: Boolean = false,
    val error: String? = null,
    val notice: String? = null,
) {
    val address: String? get() = contacts?.email
    val isVerified: Boolean get() = contacts?.emailVerified == true
    val canSave: Boolean get() = !busy && SignUpRules.isAddressShaped(draft.trim())
    val canVerify: Boolean get() = !busy && SignUpRules.normalizedCode(code).length == 6

    /** What the showing step says, in the webmail's words. */
    val statusText: String
        get() {
            val address = address
            return when {
                address == null && smsEnabled && contacts?.phoneVerified == true ->
                    "You have no recovery email. Your phone number recovers your account; an address outside " +
                        "Cabalmail also gets you back in if you lose your phone."
                address == null ->
                    "You have no recovery email. Add an address outside Cabalmail so you can get back in if you " +
                        "forget your password."
                isVerified -> "$address is verified and can be used to recover your account."
                else -> "$address is not verified yet, so it can't be used to recover your account."
            }
        }

    /**
     * The editing step's help. Changing a verified address warns first: the
     * pool keeps no pending value, so the old one stops counting at once.
     */
    val editingHelp: String
        get() =
            address?.takeIf { isVerified }?.let {
                "Use an address outside Cabalmail. Until you verify it, $it stops being used for recovery."
            } ?: "Use an address outside Cabalmail: a mailbox you're locked out of can't receive its own reset code."
}

/**
 * The recovery email (auth parity B4; `docs/auth.md`, "Recovery email"):
 * see it, add or change it, send a code and verify it. One view model
 * drives the Settings › Account page and the dialog the check after
 * sign-in raises ([recoveryEmailPrompt]); with a [prompt] it starts where
 * that points without reading `GetUser` again.
 */
class RecoveryEmailViewModel(
    private val auth: suspend () -> AuthService,
    smsEnabled: Boolean,
    prompt: RecoveryEmailPrompt? = null,
) : ViewModel() {
    private val mutableState =
        MutableStateFlow(
            when (prompt) {
                RecoveryEmailPrompt.Add ->
                    RecoveryEmailUiState(
                        step = RecoveryEmailStep.Editing,
                        smsEnabled = smsEnabled,
                        contacts = RecoveryContacts(null, emailVerified = false, phoneVerified = false),
                    )
                is RecoveryEmailPrompt.Verify ->
                    RecoveryEmailUiState(
                        step = RecoveryEmailStep.Showing,
                        smsEnabled = smsEnabled,
                        contacts = RecoveryContacts(prompt.address, emailVerified = false, phoneVerified = false),
                    )
                null -> RecoveryEmailUiState(smsEnabled = smsEnabled)
            },
        )
    val state: StateFlow<RecoveryEmailUiState> = mutableState.asStateFlow()

    init {
        if (prompt == null) load()
    }

    fun load() {
        mutableState.update { it.copy(step = RecoveryEmailStep.Loading, error = null) }
        viewModelScope.launch {
            try {
                val contacts = auth().recoveryContacts()
                mutableState.update { it.copy(step = RecoveryEmailStep.Showing, contacts = contacts) }
            } catch (exception: Exception) {
                val reason = SignUpRules.errorMessage(exception)
                mutableState.update {
                    it.copy(step = RecoveryEmailStep.Failed("Couldn't load your recovery email. $reason"))
                }
            }
        }
    }

    fun editDraft(value: String) = mutableState.update { it.copy(draft = value) }

    fun editCode(value: String) = mutableState.update { it.copy(code = value) }

    fun startEditing() =
        mutableState.update { it.copy(step = RecoveryEmailStep.Editing, draft = "", error = null, notice = null) }

    fun cancel() = mutableState.update { it.copy(step = RecoveryEmailStep.Showing, error = null) }

    fun save() {
        val current = state.value
        if (current.step != RecoveryEmailStep.Editing || !current.canSave) return
        val address = current.draft.trim()
        perform {
            auth().setRecoveryEmail(address)
            mutableState.update {
                it.copy(
                    contacts = RecoveryContacts(address, emailVerified = false, phoneVerified = it.phoneVerified),
                    code = "",
                    step = RecoveryEmailStep.Verifying,
                    notice = "A verification code is on its way to $address.",
                )
            }
        }
    }

    fun sendCode() {
        val address = state.value.address ?: return
        if (state.value.busy) return
        perform {
            auth().sendRecoveryEmailCode()
            mutableState.update {
                it.copy(
                    code = "",
                    step = RecoveryEmailStep.Verifying,
                    notice = "A verification code is on its way to $address.",
                )
            }
        }
    }

    fun verify() {
        val current = state.value
        val address = current.address ?: return
        if (current.step != RecoveryEmailStep.Verifying || !current.canVerify) return
        val code = SignUpRules.normalizedCode(current.code)
        perform {
            auth().verifyRecoveryEmail(code)
            mutableState.update {
                it.copy(
                    contacts = RecoveryContacts(address, emailVerified = true, phoneVerified = it.phoneVerified),
                    code = "",
                    step = RecoveryEmailStep.Showing,
                    notice = "Email verified. It can now be used to recover your account.",
                )
            }
        }
    }

    private val RecoveryEmailUiState.phoneVerified: Boolean get() = contacts?.phoneVerified == true

    private fun perform(action: suspend () -> Unit) {
        mutableState.update { it.copy(busy = true, error = null, notice = null) }
        viewModelScope.launch {
            try {
                action()
                mutableState.update { it.copy(busy = false) }
            } catch (exception: Exception) {
                mutableState.update { it.copy(busy = false, error = SignUpRules.errorMessage(exception)) }
            }
        }
    }

    companion object {
        fun factory(
            container: AppContainer,
            prompt: RecoveryEmailPrompt? = null,
        ): ViewModelProvider.Factory =
            viewModelFactory {
                initializer {
                    RecoveryEmailViewModel(
                        auth = { container.requireAuth() },
                        smsEnabled =
                            container.configService.config.value
                                ?.smsEnabled ?: true,
                        prompt = prompt,
                    )
                }
            }
    }
}

/**
 * The check after an interactive sign-in (`docs/auth.md`, "After sign-in";
 * plan D5): one `GetUser`, and what to ask, or null. A failed read never
 * blocks the sign-in, so it answers null.
 */
suspend fun recoveryEmailPrompt(
    auth: AuthService,
    smsEnabled: Boolean,
): RecoveryEmailPrompt? =
    try {
        auth.recoveryContacts().promptAfterSignIn(smsEnabled)
    } catch (exception: Exception) {
        if (exception is CancellationException) throw exception
        null
    }

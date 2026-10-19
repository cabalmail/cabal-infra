package com.cabalmail.android.ui.auth

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import com.cabalmail.android.AppContainer
import com.cabalmail.kit.CabalmailException
import com.cabalmail.kit.auth.AuthService
import com.cabalmail.kit.auth.AuthTokens
import com.cabalmail.kit.auth.CodeDelivery
import com.cabalmail.kit.auth.CognitoAuthService
import com.cabalmail.kit.auth.SignUpResult
import com.cabalmail.kit.auth.TokenStore
import com.cabalmail.kit.config.Config
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

/** Where the sign-up flow stands. */
sealed interface SignUpStep {
    /** Reading `config.json`, which says what the form asks for. */
    data object Loading : SignUpStep

    data class Unavailable(
        val message: String,
    ) : SignUpStep

    data object Form : SignUpStep

    /** Cognito sent a confirmation code here. */
    data class Confirm(
        val delivery: CodeDelivery,
    ) : SignUpStep

    /**
     * The account exists. [verifiedBy] is the medium whose code the user
     * entered, or null when `check_invite` confirmed it itself (no SMS).
     */
    data class Created(
        val username: String,
        val verifiedBy: CodeDelivery.Medium?,
    ) : SignUpStep
}

data class SignUpUiState(
    val controlDomain: String,
    val step: SignUpStep = SignUpStep.Loading,
    val form: SignUpForm = SignUpForm(),
    val policy: SignUpPolicy = SignUpPolicy(smsEnabled = true, invitationRequired = false),
    val operatorName: String = "",
    /** The deployment's own domain, for its front-door legal pages. */
    val deploymentDomain: String = "",
    val busy: Boolean = false,
    val error: String? = null,
    /** A resend's outcome, shown on the code step. */
    val notice: String? = null,
    /** False once Cognito has said "too many codes"; leaving resets it. */
    val canResend: Boolean = true,
) {
    val missingRequirement: String? get() = SignUpRules.missingRequirement(form, policy)
    val canSubmit: Boolean get() = step == SignUpStep.Form && !busy && missingRequirement == null
    val canConfirm: Boolean get() = !busy && SignUpRules.normalizedCode(form.code).length == 6
    val consentText: String get() = SignUpRules.consentText(operatorName)
    val termsUrl: String? get() = legalPage("terms.html")
    val privacyUrl: String? get() = legalPage("privacy.html")

    private fun legalPage(name: String): String? =
        deploymentDomain.takeIf { it.isNotBlank() }?.let { "https://www.$it/$name" }
}

/**
 * The native sign-up flow (auth parity B3): the form, the confirmation
 * code, and the account-created result, against the control domain the
 * sign-in screen holds. `docs/auth.md` ("Sign-up") is the contract.
 *
 * Sign-up makes no session: [makeAuth] is a Cognito client over a token
 * store that keeps nothing, since none of its calls return tokens. The
 * new account signs in through the ordinary form afterwards.
 */
class SignUpViewModel(
    controlDomain: String,
    private val loadConfig: suspend (String) -> Config,
    private val makeAuth: (Config) -> AuthService,
) : ViewModel() {
    private val mutableState = MutableStateFlow(SignUpUiState(controlDomain = controlDomain.trim()))
    val state: StateFlow<SignUpUiState> = mutableState.asStateFlow()

    private var auth: AuthService? = null

    /** The username Cognito holds the pending account under. */
    private var submittedUsername: String? = null

    init {
        load()
    }

    fun load() {
        mutableState.update { it.copy(step = SignUpStep.Loading, error = null) }
        viewModelScope.launch {
            try {
                val config = loadConfig(state.value.controlDomain)
                auth = makeAuth(config)
                mutableState.update {
                    it.copy(
                        step = SignUpStep.Form,
                        policy = SignUpPolicy(config.smsEnabled, config.invitationRequired),
                        operatorName = config.operatorName,
                        deploymentDomain = config.controlDomain,
                    )
                }
            } catch (exception: Exception) {
                val reason = SignUpRules.errorMessage(exception)
                mutableState.update {
                    it.copy(step = SignUpStep.Unavailable("Couldn't reach this server's sign-up. $reason"))
                }
            }
        }
    }

    fun edit(transform: (SignUpForm) -> SignUpForm) {
        mutableState.update { it.copy(form = transform(it.form)) }
    }

    fun submit() {
        val current = state.value
        val service = auth
        if (!current.canSubmit || service == null) return
        val form = current.form
        val username = SignUpRules.normalizedUsername(form.username)
        val email = form.email.trim()
        val invitation = form.invitationCode.trim()
        runStep {
            val result =
                service.signUp(
                    username = username,
                    password = form.password,
                    email = email.ifEmpty { null },
                    phone = if (current.policy.smsEnabled) SignUpRules.normalizedPhone(form.phone) else null,
                    invitationCode = invitation.ifEmpty { null },
                )
            submittedUsername = username
            mutableState.update {
                it.copy(
                    // The password is not kept once sent.
                    form = it.form.copy(password = "", confirmPassword = "", code = ""),
                    step =
                        when (result) {
                            is SignUpResult.ConfirmationCodeSent -> SignUpStep.Confirm(result.delivery)
                            SignUpResult.Confirmed -> SignUpStep.Created(username, verifiedBy = null)
                        },
                )
            }
        }
    }

    fun confirm() {
        val current = state.value
        val step = current.step as? SignUpStep.Confirm ?: return
        val service = auth ?: return
        val username = submittedUsername ?: return
        if (!current.canConfirm) return
        runStep {
            try {
                service.confirmSignUp(username, SignUpRules.normalizedCode(current.form.code))
            } catch (alreadyConfirmed: CabalmailException.InvalidCredentials) {
                // ConfirmSignUp's NotAuthorizedException: the account is
                // already confirmed (a second tap, or an admin confirmed it).
            }
            mutableState.update { it.copy(step = SignUpStep.Created(username, step.delivery.medium)) }
        }
    }

    fun resend() {
        val current = state.value
        val step = current.step as? SignUpStep.Confirm ?: return
        val service = auth ?: return
        val username = submittedUsername ?: return
        if (!current.canResend || current.busy) return
        runStep {
            val delivery = service.resendConfirmationCode(username) ?: step.delivery
            mutableState.update {
                it.copy(
                    step = SignUpStep.Confirm(delivery),
                    notice = "A new code is on its way to ${SignUpRules.describe(delivery)}.",
                )
            }
        }
    }

    private fun runStep(action: suspend () -> Unit) {
        mutableState.update { it.copy(busy = true, error = null, notice = null) }
        viewModelScope.launch {
            try {
                action()
                mutableState.update { it.copy(busy = false) }
            } catch (exception: Exception) {
                mutableState.update {
                    it.copy(
                        busy = false,
                        error = SignUpRules.errorMessage(exception),
                        canResend = it.canResend && !SignUpRules.isRateLimit(exception),
                    )
                }
            }
        }
    }

    companion object {
        fun factory(
            container: AppContainer,
            controlDomain: String,
        ): ViewModelProvider.Factory =
            viewModelFactory {
                initializer {
                    SignUpViewModel(
                        controlDomain = controlDomain,
                        // The same load sign-in does, so the config this
                        // install remembers is the server signed up on.
                        loadConfig = { container.configService.load(it) },
                        makeAuth = { config ->
                            CognitoAuthService(
                                clientId = config.cognitoClientId,
                                region = config.cognito.region,
                                httpClient = container.httpClient,
                                tokenStore = NoTokens,
                            )
                        },
                    )
                }
            }
    }
}

/** Sign-up stores nothing: no call it makes returns tokens. */
private object NoTokens : TokenStore {
    override fun readTokens(): AuthTokens? = null

    override fun writeTokens(tokens: AuthTokens) = Unit

    override fun readUsername(): String? = null

    override fun writeUsername(username: String) = Unit

    override fun clear() = Unit
}

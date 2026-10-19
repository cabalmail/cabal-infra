package com.cabalmail.android.ui.auth

import com.cabalmail.kit.CabalmailException
import com.cabalmail.kit.auth.AuthService
import com.cabalmail.kit.auth.AuthTokens
import com.cabalmail.kit.auth.CodeDelivery
import com.cabalmail.kit.auth.SignInResult
import com.cabalmail.kit.auth.SignUpResult
import com.cabalmail.kit.config.CognitoConfig
import com.cabalmail.kit.config.CognitoPool
import com.cabalmail.kit.config.Config
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import org.junit.jupiter.api.AfterEach
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.BeforeEach
import org.junit.jupiter.api.Test
import java.io.IOException

/**
 * [SignUpViewModel] against a scripted [AuthService] (auth parity B3): what
 * `signUp`, `confirmSignUp` and `resendConfirmationCode` are called with,
 * and where each reply or refusal leaves the flow. The virtual-time
 * dispatcher drives `viewModelScope`.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class SignUpViewModelTest {
    private val dispatcher = StandardTestDispatcher()

    @BeforeEach
    fun setUp() {
        Dispatchers.setMain(dispatcher)
    }

    @AfterEach
    fun tearDown() {
        Dispatchers.resetMain()
    }

    private class FakeAuth : AuthService {
        data class SignUpCall(
            val username: String,
            val password: String,
            val email: String?,
            val phone: String?,
            val invitationCode: String?,
        )

        val signUps = mutableListOf<SignUpCall>()
        val confirms = mutableListOf<Pair<String, String>>()
        val resends = mutableListOf<String>()
        var signUpResult: () -> SignUpResult = {
            SignUpResult.ConfirmationCodeSent(CodeDelivery(CodeDelivery.Medium.PHONE, "+*******4567"))
        }
        var confirmResult: () -> Unit = {}
        var resendResult: () -> CodeDelivery? = { null }

        override suspend fun signUp(
            username: String,
            password: String,
            email: String?,
            phone: String?,
            invitationCode: String?,
        ): SignUpResult {
            signUps += SignUpCall(username, password, email, phone, invitationCode)
            return signUpResult()
        }

        override suspend fun confirmSignUp(
            username: String,
            code: String,
        ) {
            confirms += username to code
            confirmResult()
        }

        override suspend fun resendConfirmationCode(username: String): CodeDelivery? {
            resends += username
            return resendResult()
        }

        override suspend fun signIn(
            username: String,
            password: String,
        ): SignInResult = error("sign-up never signs in")

        override suspend fun submitMfaCode(code: String) = error("sign-up never signs in")

        override suspend fun forgotPassword(username: String) = Unit

        override suspend fun confirmForgotPassword(
            username: String,
            code: String,
            newPassword: String,
        ) = Unit

        override suspend fun signOut() = Unit

        override suspend fun currentIdToken(): String = error("sign-up has no session")

        override suspend fun forceRefreshedIdToken(): String = error("sign-up has no session")

        override fun currentUsername(): String? = null

        override fun currentTokens(): AuthTokens? = null
    }

    private fun config(
        sms: Boolean = true,
        invitation: Boolean = true,
        operatorName: String = "",
    ) = Config(
        controlDomain = "cabalmail.example",
        invokeUrl = "https://api.cabalmail.example/prod",
        cognito = CognitoConfig("us-east-1", CognitoPool("u", "c")),
        invitationRequired = invitation,
        smsEnabled = sms,
        operatorName = operatorName,
    )

    private fun TestScope.loaded(
        auth: FakeAuth = FakeAuth(),
        config: Config = config(),
    ): SignUpViewModel {
        val viewModel = SignUpViewModel(" cabalmail.example ", loadConfig = { config }, makeAuth = { auth })
        advanceUntilIdle()
        return viewModel
    }

    private fun SignUpViewModel.fill() =
        edit {
            it.copy(
                username = "  Alice ",
                phone = "+1 (555) 123-4567",
                invitationCode = " OPEN-SESAME ",
                password = "Correct-Horse-9",
                confirmPassword = "Correct-Horse-9",
                smsConsent = true,
            )
        }

    @Test
    fun `loading reads what the deployment asks for`() =
        runTest(dispatcher) {
            var asked = ""
            val viewModel =
                SignUpViewModel(" cabalmail.example ", loadConfig = {
                    asked = it
                    config(sms = false, invitation = true, operatorName = "Example Operator LLC")
                }, makeAuth = { FakeAuth() })
            advanceUntilIdle()

            val state = viewModel.state.value
            assertEquals("cabalmail.example", asked)
            assertEquals(SignUpStep.Form, state.step)
            assertEquals(SignUpPolicy(smsEnabled = false, invitationRequired = true), state.policy)
            assertTrue(state.consentText.contains("Cabalmail (Example Operator LLC)"))
            assertEquals("https://www.cabalmail.example/terms.html", state.termsUrl)
        }

    @Test
    fun `an unreadable configuration offers a retry`() =
        runTest(dispatcher) {
            var attempts = 0
            val viewModel =
                SignUpViewModel("cabalmail.example", loadConfig = {
                    attempts += 1
                    if (attempts == 1) throw IOException("offline")
                    config()
                }, makeAuth = { FakeAuth() })
            advanceUntilIdle()
            val step = viewModel.state.value.step
            assertTrue(
                step is SignUpStep.Unavailable && step.message.startsWith("Couldn't reach this server's sign-up."),
            )

            viewModel.load()
            advanceUntilIdle()
            assertEquals(SignUpStep.Form, viewModel.state.value.step)
        }

    @Test
    fun `submit sends the normalized fields and asks for the code`() =
        runTest(dispatcher) {
            val auth = FakeAuth()
            val viewModel = loaded(auth)
            viewModel.fill()
            viewModel.submit()
            advanceUntilIdle()

            assertEquals(
                FakeAuth.SignUpCall(
                    username = "alice",
                    password = "Correct-Horse-9",
                    // No email given, so none is sent: Cabalmail can be someone's only email.
                    email = null,
                    phone = "+15551234567",
                    invitationCode = "OPEN-SESAME",
                ),
                auth.signUps.single(),
            )
            val state = viewModel.state.value
            assertEquals(SignUpStep.Confirm(CodeDelivery(CodeDelivery.Medium.PHONE, "+*******4567")), state.step)
            assertEquals("", state.form.password, "the password is not kept once sent")
        }

    @Test
    fun `an incomplete form is not sent`() =
        runTest(dispatcher) {
            val auth = FakeAuth()
            val viewModel = loaded(auth)
            viewModel.fill()
            viewModel.edit { it.copy(smsConsent = false) }
            viewModel.submit()
            advanceUntilIdle()

            assertTrue(auth.signUps.isEmpty())
            assertEquals(SignUpStep.Form, viewModel.state.value.step)
        }

    @Test
    fun `an auto-confirmed account is created at once`() =
        runTest(dispatcher) {
            val auth = FakeAuth().apply { signUpResult = { SignUpResult.Confirmed } }
            val viewModel = loaded(auth, config(sms = false))
            viewModel.edit {
                it.copy(
                    username = "alice",
                    email = "alice@example.net",
                    invitationCode = "OPEN-SESAME",
                    password = "Correct-Horse-9",
                    confirmPassword = "Correct-Horse-9",
                )
            }
            viewModel.submit()
            advanceUntilIdle()

            assertEquals(SignUpStep.Created("alice", verifiedBy = null), viewModel.state.value.step)
            assertEquals(null, auth.signUps.single().phone, "no phone is sent without SMS")
        }

    @Test
    fun `a refusal stays on the form with a sentence`() =
        runTest(dispatcher) {
            val auth = FakeAuth().apply { signUpResult = { throw CabalmailException.InvalidInvitationCode() } }
            val viewModel = loaded(auth)
            viewModel.fill()
            viewModel.submit()
            advanceUntilIdle()

            val state = viewModel.state.value
            assertEquals(SignUpStep.Form, state.step)
            assertEquals("Invalid invitation code.", state.error)
            assertEquals("Correct-Horse-9", state.form.password, "a refused form keeps what was typed")
        }

    private fun TestScope.atTheCode(auth: FakeAuth): SignUpViewModel {
        val viewModel = loaded(auth)
        viewModel.fill()
        viewModel.submit()
        advanceUntilIdle()
        return viewModel
    }

    @Test
    fun `confirm sends the code for the username that was submitted`() =
        runTest(dispatcher) {
            val auth = FakeAuth()
            val viewModel = atTheCode(auth)
            viewModel.edit { it.copy(username = "someone-else", code = " 123 456 ") }
            assertTrue(viewModel.state.value.canConfirm)
            viewModel.confirm()
            advanceUntilIdle()

            assertEquals("alice" to "123456", auth.confirms.single())
            assertEquals(SignUpStep.Created("alice", CodeDelivery.Medium.PHONE), viewModel.state.value.step)
        }

    @Test
    fun `a wrong code stays on the code`() =
        runTest(dispatcher) {
            val auth =
                FakeAuth().apply {
                    confirmResult =
                        { throw CabalmailException.ServerError("CodeMismatchException", "x") }
                }
            val viewModel = atTheCode(auth)
            viewModel.edit { it.copy(code = "000000") }
            viewModel.confirm()
            advanceUntilIdle()

            val state = viewModel.state.value
            assertTrue(state.step is SignUpStep.Confirm)
            assertEquals("That code did not match. Check it and try again.", state.error)
        }

    /** NotAuthorizedException on a second confirmation: the account exists either way. */
    @Test
    fun `an already confirmed account counts as created`() =
        runTest(dispatcher) {
            val auth = FakeAuth().apply { confirmResult = { throw CabalmailException.InvalidCredentials() } }
            val viewModel = atTheCode(auth)
            viewModel.edit { it.copy(code = "123456") }
            viewModel.confirm()
            advanceUntilIdle()

            assertEquals(SignUpStep.Created("alice", CodeDelivery.Medium.PHONE), viewModel.state.value.step)
        }

    @Test
    fun `resend says where the code went and stops when Cognito limits it`() =
        runTest(dispatcher) {
            val auth = FakeAuth().apply { resendResult = { CodeDelivery(CodeDelivery.Medium.PHONE, "+*******9999") } }
            val viewModel = atTheCode(auth)
            viewModel.resend()
            advanceUntilIdle()

            assertEquals(listOf("alice"), auth.resends)
            assertEquals("A new code is on its way to your phone (+*******9999).", viewModel.state.value.notice)
            assertEquals(
                SignUpStep.Confirm(CodeDelivery(CodeDelivery.Medium.PHONE, "+*******9999")),
                viewModel.state.value.step,
            )

            auth.resendResult = { throw CabalmailException.ServerError("LimitExceededException", "x") }
            viewModel.resend()
            advanceUntilIdle()
            assertFalse(viewModel.state.value.canResend)
            assertEquals("Too many attempts. Please try again later.", viewModel.state.value.error)
        }
}

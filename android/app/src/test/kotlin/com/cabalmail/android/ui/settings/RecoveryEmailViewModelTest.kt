package com.cabalmail.android.ui.settings

import com.cabalmail.kit.CabalmailException
import com.cabalmail.kit.auth.AuthService
import com.cabalmail.kit.auth.AuthTokens
import com.cabalmail.kit.auth.CodeDelivery
import com.cabalmail.kit.auth.RecoveryContacts
import com.cabalmail.kit.auth.RecoveryEmailPrompt
import com.cabalmail.kit.auth.SignInResult
import com.cabalmail.kit.auth.SignUpResult
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import org.junit.jupiter.api.AfterEach
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.BeforeEach
import org.junit.jupiter.api.Test

/**
 * [RecoveryEmailViewModel] and [recoveryEmailPrompt] against a scripted
 * [AuthService] (auth parity B4): what the settings page and the dialog
 * after sign-in show, and where adding, verifying and failing leave them.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class RecoveryEmailViewModelTest {
    private val dispatcher = StandardTestDispatcher()

    @BeforeEach
    fun setUp() {
        Dispatchers.setMain(dispatcher)
    }

    @AfterEach
    fun tearDown() {
        Dispatchers.resetMain()
    }

    private class FakeAuth(
        var contacts: () -> RecoveryContacts = { RecoveryContacts(null, emailVerified = false, phoneVerified = false) },
    ) : AuthService {
        val calls = mutableListOf<String>()
        var verifyResult: () -> Unit = {}

        override suspend fun recoveryContacts(): RecoveryContacts {
            calls += "GetUser"
            return contacts()
        }

        override suspend fun setRecoveryEmail(address: String) {
            calls += "UpdateUserAttributes $address"
        }

        override suspend fun sendRecoveryEmailCode() {
            calls += "GetUserAttributeVerificationCode"
        }

        override suspend fun verifyRecoveryEmail(code: String) {
            calls += "VerifyUserAttribute $code"
            verifyResult()
        }

        override suspend fun signIn(
            username: String,
            password: String,
        ): SignInResult = error("unused")

        override suspend fun submitMfaCode(code: String) = Unit

        override suspend fun signUp(
            username: String,
            password: String,
            email: String?,
            phone: String?,
            invitationCode: String?,
        ): SignUpResult = error("unused")

        override suspend fun confirmSignUp(
            username: String,
            code: String,
        ) = Unit

        override suspend fun resendConfirmationCode(username: String): CodeDelivery? = null

        override suspend fun forgotPassword(username: String) = Unit

        override suspend fun confirmForgotPassword(
            username: String,
            code: String,
            newPassword: String,
        ) = Unit

        override suspend fun signOut() = Unit

        override suspend fun currentIdToken(): String = "id"

        override suspend fun forceRefreshedIdToken(): String = "id"

        override fun currentUsername(): String? = "alice"

        override fun currentTokens(): AuthTokens? = null
    }

    @Test
    fun `a verified address is shown as such`() =
        runTest(dispatcher) {
            val auth = FakeAuth({ RecoveryContacts("alice@example.net", emailVerified = true, phoneVerified = false) })
            val viewModel = RecoveryEmailViewModel({ auth }, smsEnabled = true)
            advanceUntilIdle()

            assertEquals(RecoveryEmailStep.Showing, viewModel.state.value.step)
            assertEquals(
                "alice@example.net is verified and can be used to recover your account.",
                viewModel.state.value.statusText,
            )
        }

    /** The settings page is where a phone-only account (plan D5) adds an address. */
    @Test
    fun `a phone-only account is told its phone recovers it`() =
        runTest(dispatcher) {
            val auth = FakeAuth({ RecoveryContacts(null, emailVerified = false, phoneVerified = true) })
            val viewModel = RecoveryEmailViewModel({ auth }, smsEnabled = true)
            advanceUntilIdle()

            assertTrue(
                viewModel.state.value.statusText
                    .startsWith("You have no recovery email. Your phone number recovers your account"),
            )
        }

    @Test
    fun `adding an address saves it then verifies it`() =
        runTest(dispatcher) {
            val auth = FakeAuth()
            val viewModel = RecoveryEmailViewModel({ auth }, smsEnabled = false)
            advanceUntilIdle()

            viewModel.startEditing()
            viewModel.editDraft("not an address")
            assertFalse(viewModel.state.value.canSave)
            viewModel.editDraft(" alice@example.net ")
            viewModel.save()
            advanceUntilIdle()
            assertEquals(RecoveryEmailStep.Verifying, viewModel.state.value.step)
            assertEquals("A verification code is on its way to alice@example.net.", viewModel.state.value.notice)

            viewModel.editCode("424 242")
            viewModel.verify()
            advanceUntilIdle()

            assertEquals(RecoveryEmailStep.Showing, viewModel.state.value.step)
            assertTrue(viewModel.state.value.isVerified)
            assertEquals(
                listOf("GetUser", "UpdateUserAttributes alice@example.net", "VerifyUserAttribute 424242"),
                auth.calls,
            )
        }

    @Test
    fun `changing a verified address warns it stops counting`() =
        runTest(dispatcher) {
            val auth = FakeAuth({ RecoveryContacts("alice@example.net", emailVerified = true, phoneVerified = false) })
            val viewModel = RecoveryEmailViewModel({ auth }, smsEnabled = true)
            advanceUntilIdle()
            viewModel.startEditing()

            assertEquals(
                "Use an address outside Cabalmail. Until you verify it, alice@example.net stops being used for recovery.",
                viewModel.state.value.editingHelp,
            )
        }

    @Test
    fun `a wrong code stays on the code`() =
        runTest(dispatcher) {
            val auth =
                FakeAuth(
                    { RecoveryContacts("alice@example.net", emailVerified = false, phoneVerified = false) },
                ).apply {
                    verifyResult = { throw CabalmailException.ServerError("CodeMismatchException", "Invalid code") }
                }
            val viewModel = RecoveryEmailViewModel({ auth }, smsEnabled = true)
            advanceUntilIdle()
            viewModel.sendCode()
            advanceUntilIdle()
            viewModel.editCode("000000")
            viewModel.verify()
            advanceUntilIdle()

            assertEquals(RecoveryEmailStep.Verifying, viewModel.state.value.step)
            assertFalse(viewModel.state.value.isVerified)
            assertEquals("That code did not match. Check it and try again.", viewModel.state.value.error)
        }

    @Test
    fun `an unreadable account offers a retry`() =
        runTest(dispatcher) {
            var attempts = 0
            val auth =
                FakeAuth({
                    attempts += 1
                    if (attempts == 1) throw CabalmailException.ServerError("InternalErrorException", "boom")
                    RecoveryContacts("alice@example.net", emailVerified = true, phoneVerified = false)
                })
            val viewModel = RecoveryEmailViewModel({ auth }, smsEnabled = true)
            advanceUntilIdle()
            assertTrue(viewModel.state.value.step is RecoveryEmailStep.Failed)

            viewModel.load()
            advanceUntilIdle()
            assertEquals(RecoveryEmailStep.Showing, viewModel.state.value.step)
        }

    @Test
    fun `the prompt starts where it points without reading GetUser`() =
        runTest(dispatcher) {
            val auth = FakeAuth()
            val adding = RecoveryEmailViewModel({ auth }, smsEnabled = false, prompt = RecoveryEmailPrompt.Add)
            val verifying =
                RecoveryEmailViewModel(
                    { auth },
                    smsEnabled = true,
                    prompt = RecoveryEmailPrompt.Verify("alice@example.net"),
                )
            advanceUntilIdle()

            assertEquals(RecoveryEmailStep.Editing, adding.state.value.step)
            assertEquals(RecoveryEmailStep.Showing, verifying.state.value.step)
            assertEquals("alice@example.net", verifying.state.value.address)
            assertTrue(auth.calls.isEmpty())
        }

    @Test
    fun `the check asks what D5 asks`() =
        runTest(dispatcher) {
            val phoneOnly = FakeAuth({ RecoveryContacts(null, emailVerified = false, phoneVerified = true) })
            assertNull(recoveryEmailPrompt(phoneOnly, smsEnabled = true), "a verified phone recovers it when SMS is on")
            assertEquals(RecoveryEmailPrompt.Add, recoveryEmailPrompt(phoneOnly, smsEnabled = false))

            val unverified =
                FakeAuth({ RecoveryContacts("alice@example.net", emailVerified = false, phoneVerified = true) })
            assertEquals(
                RecoveryEmailPrompt.Verify("alice@example.net"),
                recoveryEmailPrompt(unverified, smsEnabled = true),
            )
        }

    @Test
    fun `a failed check never blocks the sign-in`() =
        runTest(dispatcher) {
            val failing = FakeAuth({ throw CabalmailException.ServerError("InternalErrorException", "boom") })
            assertNull(recoveryEmailPrompt(failing, smsEnabled = true))
        }
}

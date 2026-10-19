package com.cabalmail.android.ui.auth

import com.cabalmail.kit.CabalmailException
import com.cabalmail.kit.auth.CodeDelivery
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

/**
 * [SignUpRules] (auth parity B3): what each deployment's form asks for
 * (plan D5), how fields are normalized, and the copy, matching the webmail
 * and the Apple app.
 */
class SignUpRulesTest {
    private val sms = SignUpPolicy(smsEnabled = true, invitationRequired = true)
    private val noSms = SignUpPolicy(smsEnabled = false, invitationRequired = false)

    private val complete =
        SignUpForm(
            username = "  Alice ",
            phone = "+1 (555) 123-4567",
            invitationCode = " OPEN-SESAME ",
            password = "Correct-Horse-9",
            confirmPassword = "Correct-Horse-9",
            smsConsent = true,
        )

    @Test
    fun `with SMS the phone and consent are required and the email is optional`() {
        assertNull(SignUpRules.missingRequirement(complete, sms))
        assertEquals(
            "Agree to receive SMS to continue.",
            SignUpRules.missingRequirement(complete.copy(smsConsent = false), sms),
        )
        assertEquals("Enter your phone number.", SignUpRules.missingRequirement(complete.copy(phone = ""), sms))
        assertEquals(
            "Enter the phone number with its country code, starting with +.",
            SignUpRules.missingRequirement(complete.copy(phone = "555 123 4567"), sms),
        )
        assertEquals(
            "That email address doesn't look right.",
            SignUpRules.missingRequirement(complete.copy(email = "not an address"), sms),
        )
        assertNull(SignUpRules.missingRequirement(complete.copy(email = "alice@example.net"), sms))
    }

    @Test
    fun `without SMS the email is required and no phone or consent is asked`() {
        val form = complete.copy(phone = "", smsConsent = false)
        assertEquals("Enter a recovery email.", SignUpRules.missingRequirement(form, noSms))
        assertNull(SignUpRules.missingRequirement(form.copy(email = "alice@example.net"), noSms))
    }

    @Test
    fun `the invitation code is required only when the deployment says so`() {
        assertEquals(
            "Enter your invitation code.",
            SignUpRules.missingRequirement(complete.copy(invitationCode = "  "), sms),
        )
        assertNull(
            SignUpRules.missingRequirement(complete.copy(invitationCode = ""), sms.copy(invitationRequired = false)),
        )
    }

    @Test
    fun `passwords must be long enough and match`() {
        assertEquals(
            "Use a password of at least 12 characters.",
            SignUpRules.missingRequirement(complete.copy(password = "Short-9", confirmPassword = "Short-9"), sms),
        )
        assertEquals(
            "The passwords don't match.",
            SignUpRules.missingRequirement(complete.copy(confirmPassword = "Correct-Horse-8"), sms),
        )
    }

    @Test
    fun `username rules match check_invite`() {
        listOf("abc", "a-b", "abc123", "a".repeat(32)).forEach { assertTrue(SignUpRules.isValidUsername(it), it) }
        listOf("ab", "-abc", "abc-", "123", "a_b", "a.b", "a".repeat(33), "ABC").forEach {
            assertFalse(SignUpRules.isValidUsername(it), it)
        }
        assertEquals("alice", SignUpRules.normalizedUsername("  Alice "))
    }

    @Test
    fun `phone numbers are sent as E164`() {
        assertEquals("+15551234567", SignUpRules.normalizedPhone("+1 (555) 123-4567"))
        assertTrue(SignUpRules.isE164("+15551234567"))
        assertFalse(SignUpRules.isE164("+05551234567"), "a country code never starts with 0")
        // Digits from other scripts are not digits Cognito accepts.
        assertEquals("+", SignUpRules.normalizedPhone("+١٥٥٥١٢٣٤٥٦٧"))
    }

    @Test
    fun `the consent text names the operator when the deployment does`() {
        assertTrue(
            SignUpRules
                .consentText("Example Operator LLC")
                .startsWith("I agree to receive transactional SMS from Cabalmail (Example Operator LLC) — signup"),
        )
        assertTrue(
            SignUpRules.consentText("").startsWith("I agree to receive transactional SMS from Cabalmail — signup"),
        )
    }

    @Test
    fun `refusals get a sentence a person can act on`() {
        fun server(
            code: String,
            message: String,
        ) = SignUpRules.errorMessage(CabalmailException.ServerError(code, message))

        assertEquals("Invalid invitation code.", SignUpRules.errorMessage(CabalmailException.InvalidInvitationCode()))
        assertEquals(
            "That username is reserved. Choose another.",
            server("UserLambdaValidationException", "That username is reserved. Choose another."),
        )
        assertEquals(
            "That username is taken. Choose another.",
            server("UsernameExistsException", "User already exists"),
        )
        assertEquals(
            "Password must have uppercase characters.",
            server(
                "InvalidPasswordException",
                "Password did not conform with policy: Password must have uppercase characters",
            ),
        )
        assertEquals(
            "Invalid phone number format.",
            server("InvalidParameterException", "Invalid phone number format."),
        )
        assertEquals(
            "That code did not match. Check it and try again.",
            server("CodeMismatchException", "Invalid code"),
        )
        assertEquals("Too many attempts. Please try again later.", server("LimitExceededException", "Attempt limit"))
        assertTrue(SignUpRules.isRateLimit(CabalmailException.ServerError("LimitExceededException", "x")))
        assertFalse(SignUpRules.isRateLimit(CabalmailException.ServerError("CodeMismatchException", "x")))
    }

    @Test
    fun `a code delivery says where the code went`() {
        assertEquals(
            "your phone (+*******4567)",
            SignUpRules.describe(CodeDelivery(CodeDelivery.Medium.PHONE, "+*******4567")),
        )
        assertEquals("your email", SignUpRules.describe(CodeDelivery(CodeDelivery.Medium.EMAIL, null)))
    }
}

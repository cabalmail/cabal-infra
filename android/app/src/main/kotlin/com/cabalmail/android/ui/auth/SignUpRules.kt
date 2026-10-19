package com.cabalmail.android.ui.auth

import com.cabalmail.android.userMessage
import com.cabalmail.kit.CabalmailException
import com.cabalmail.kit.auth.CodeDelivery

/** What the sign-up form holds, as typed. */
data class SignUpForm(
    val username: String = "",
    val phone: String = "",
    val email: String = "",
    val invitationCode: String = "",
    val password: String = "",
    val confirmPassword: String = "",
    val smsConsent: Boolean = false,
    val code: String = "",
)

/**
 * What a deployment's sign-up asks for, from its `config.json` (plan D5):
 * with SMS, a phone with consent and an optional recovery email; without,
 * a required recovery email; the invitation code when `check_invite`
 * wants one.
 */
data class SignUpPolicy(
    val smsEnabled: Boolean,
    val invitationRequired: Boolean,
)

/**
 * The sign-up rules and copy (auth parity B3), kept free of Android so the
 * JVM tests reach them. `docs/auth.md` ("Sign-up") is the contract; the
 * webmail's `SignUp` view and the Apple app's `SignUpModel` hold the same
 * rules.
 */
object SignUpRules {
    /** The webmail's floor; Cognito's own policy reports the rest. */
    const val MIN_PASSWORD_LENGTH = 12

    /** Trimmed and lowercased: `check_invite` accepts lowercase only. */
    fun normalizedUsername(raw: String): String = raw.trim().lowercase()

    /** E.164: the spaces, dashes, dots and brackets people type dropped. */
    fun normalizedPhone(raw: String): String = raw.filter { it == '+' || it in '0'..'9' }

    /** The code's digits, whatever else a paste carried. */
    fun normalizedCode(raw: String): String = raw.filter { it in '0'..'9' }

    /**
     * 3–32 lowercase letters, digits and hyphens, no hyphen at either end,
     * at least one letter: the webmail's rule, which `check_invite` enforces.
     */
    fun isValidUsername(name: String): Boolean = USERNAME_SHAPE.matches(name) && name.any { it in 'a'..'z' }

    fun isAddressShaped(address: String): Boolean = ADDRESS_SHAPE.matches(address)

    /** `+`, a country code that doesn't start with 0, 7 to 15 digits in all. */
    fun isE164(phone: String): Boolean = E164_SHAPE.matches(phone)

    /**
     * The first thing still keeping Create account disabled, in field order,
     * so a disabled button never goes unexplained; null when the form can be
     * sent.
     */
    fun missingRequirement(
        form: SignUpForm,
        policy: SignUpPolicy,
    ): String? {
        val username = normalizedUsername(form.username)
        val phone = normalizedPhone(form.phone)
        val email = form.email.trim()
        return when {
            username.isEmpty() -> "Choose a username."
            !isValidUsername(username) ->
                "Usernames are 3 to 32 lowercase letters, numbers and hyphens, with at least one letter " +
                    "and no hyphen at either end."
            policy.smsEnabled && phone.isEmpty() -> "Enter your phone number."
            policy.smsEnabled && !isE164(phone) -> "Enter the phone number with its country code, starting with +."
            email.isEmpty() && !policy.smsEnabled -> "Enter a recovery email."
            email.isNotEmpty() && !isAddressShaped(email) -> "That email address doesn't look right."
            policy.invitationRequired && form.invitationCode.isBlank() -> "Enter your invitation code."
            form.password.length < MIN_PASSWORD_LENGTH ->
                "Use a password of at least $MIN_PASSWORD_LENGTH characters."
            form.confirmPassword.isEmpty() -> "Confirm your password."
            form.confirmPassword != form.password -> "The passwords don't match."
            policy.smsEnabled && !form.smsConsent -> "Agree to receive SMS to continue."
            else -> null
        }
    }

    /**
     * The webmail's checkbox text, word for word (`SignUp/index.jsx`), with
     * the brand built the same way: `Cabalmail (<operator>)` when
     * `config.json` names the operator, Cabalmail alone otherwise.
     */
    fun consentText(operatorName: String): String {
        val brand = if (operatorName.isBlank()) "Cabalmail" else "Cabalmail ($operatorName)"
        return "I agree to receive transactional SMS from $brand — signup verification, " +
            "password reset, and sign-in codes — at the phone number above. Message " +
            "frequency varies; message and data rates may apply. Reply HELP for help or " +
            "STOP to opt out at any time."
    }

    /** "your phone (+*******0123)", "your email (a***@e***)". */
    fun describe(delivery: CodeDelivery): String {
        val medium = if (delivery.medium == CodeDelivery.Medium.EMAIL) "your email" else "your phone"
        return delivery.destination?.takeIf { it.isNotBlank() }?.let { "$medium ($it)" } ?: medium
    }

    /** Cognito's per-user limit on sending codes, or on attempts. */
    fun isRateLimit(error: Throwable): Boolean = (error as? CabalmailException.ServerError)?.code in RATE_LIMIT_CODES

    /**
     * What the sign-up screens say when Cognito refuses a step
     * (`docs/auth.md`, "Transport and errors"). The kit leaves most of these
     * as a `ServerError` named by Cognito's exception; each one a person can
     * act on gets its own sentence.
     */
    fun errorMessage(error: Throwable): String {
        if (error is CabalmailException.InvalidInvitationCode) return error.message.orEmpty()
        val server = error as? CabalmailException.ServerError
        val message = server?.message.orEmpty()
        return when (server?.code) {
            null -> userMessage(error, "Couldn't reach the server")
            in RATE_LIMIT_CODES -> "Too many attempts. Please try again later."
            // check_invite refusing the username; the kit stripped Cognito's wrapper.
            "UserLambdaValidationException" -> sentence(message)
            "UsernameExistsException" -> "That username is taken. Choose another."
            // "Password did not conform with policy: Password must have
            // uppercase characters" — the part after the colon says what to change.
            "InvalidPasswordException" -> sentence(message.substringAfter("policy: "))
            // "Invalid phone number format.", "Invalid email address format."
            "InvalidParameterException" -> sentence(message)
            "CodeMismatchException" -> "That code did not match. Check it and try again."
            "ExpiredCodeException" -> "That code has expired. Send a new one."
            "CodeDeliveryFailureException" ->
                "Couldn't send a verification code. Check the phone number or email and try again."
            else -> userMessage(error, "Couldn't create the account")
        }
    }

    /** Cognito's messages arrive with and without a full stop. */
    private fun sentence(text: String): String {
        val trimmed = text.trim()
        return if (trimmed.isEmpty() || trimmed.endsWith(".")) trimmed else "$trimmed."
    }

    private val RATE_LIMIT_CODES =
        setOf("LimitExceededException", "TooManyRequestsException", "TooManyFailedAttemptsException")
    private val USERNAME_SHAPE = Regex("[a-z0-9][a-z0-9-]{1,30}[a-z0-9]")
    private val ADDRESS_SHAPE = Regex("""[^\s@]+@[^\s@]+\.[^\s@]+""")
    private val E164_SHAPE = Regex("""\+[1-9][0-9]{6,14}""")
}

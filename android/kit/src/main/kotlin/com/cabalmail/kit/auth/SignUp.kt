package com.cabalmail.kit.auth

import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull

/** Where Cognito sent a one-time code, from a reply's `CodeDeliveryDetails`. */
data class CodeDelivery(
    val medium: Medium,
    /** Masked by Cognito (`a***@e***`, `+*******1234`); null when the reply leaves it out. */
    val destination: String?,
) {
    enum class Medium {
        EMAIL,

        /** A text message (`DeliveryMedium: SMS`). */
        PHONE,
    }

    internal companion object {
        /**
         * Null when the reply carries no `CodeDeliveryDetails`: Cognito sent
         * no code. Anything but `EMAIL` reads as a phone, as the webmail
         * reads it.
         */
        fun from(details: JsonElement?): CodeDelivery? {
            val obj = details as? JsonObject ?: return null
            val medium = (obj["DeliveryMedium"] as? JsonPrimitive)?.contentOrNull
            return CodeDelivery(
                medium = if (medium == "EMAIL") Medium.EMAIL else Medium.PHONE,
                destination = (obj["Destination"] as? JsonPrimitive)?.contentOrNull,
            )
        }
    }
}

/**
 * Outcome of [AuthService.signUp]. Either way the account exists; the
 * sign-up screens call it pending admin approval, which in practice is the
 * domain grant (`docs/auth.md`, "Sign-up").
 */
sealed interface SignUpResult {
    /**
     * Cognito sent a confirmation code. Finish with
     * [AuthService.confirmSignUp], offering [AuthService.resendConfirmationCode].
     */
    data class ConfirmationCodeSent(
        val delivery: CodeDelivery,
    ) : SignUpResult

    /**
     * `check_invite` confirmed the account itself, because the pool has no
     * SMS and so no code to send. There is nothing to enter.
     */
    data object Confirmed : SignUpResult

    companion object {
        internal fun from(reply: JsonObject): SignUpResult =
            CodeDelivery.from(reply["CodeDeliveryDetails"])?.let(::ConfirmationCodeSent) ?: Confirmed
    }
}

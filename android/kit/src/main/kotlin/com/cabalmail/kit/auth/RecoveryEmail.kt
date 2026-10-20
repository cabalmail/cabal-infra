package com.cabalmail.kit.auth

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull

/**
 * The signed-in user's ways back in, from `GetUser`'s attributes: the
 * recovery email and whether it is verified, and whether the phone is
 * verified (`docs/auth.md`, "After sign-in" and "Recovery email").
 */
data class RecoveryContacts(
    /** Null when the account has none. */
    val email: String?,
    val emailVerified: Boolean,
    val phoneVerified: Boolean,
) {
    /**
     * What to ask right after a sign-in, or null for nothing (plan D5): to
     * verify an email the user gave but never verified, whatever the phone
     * says; to add one when there is none, unless the pool has SMS and the
     * phone is verified, since the phone then recovers the account. The
     * webmail and the Apple app ask the same.
     */
    fun promptAfterSignIn(smsEnabled: Boolean): RecoveryEmailPrompt? {
        val address = email?.takeIf { it.isNotEmpty() }
        return when {
            address != null -> if (emailVerified) null else RecoveryEmailPrompt.Verify(address)
            smsEnabled && phoneVerified -> null
            else -> RecoveryEmailPrompt.Add
        }
    }

    internal companion object {
        /** From a `GetUser` reply's `UserAttributes` (`[{Name, Value}]`). */
        fun from(reply: JsonObject): RecoveryContacts {
            val attributes =
                (reply["UserAttributes"] as? JsonArray)
                    .orEmpty()
                    .mapNotNull { it as? JsonObject }
                    .mapNotNull { attribute ->
                        val name = (attribute["Name"] as? JsonPrimitive)?.contentOrNull
                        val value = (attribute["Value"] as? JsonPrimitive)?.contentOrNull
                        if (name != null && value != null) name to value else null
                    }.toMap()
            return RecoveryContacts(
                email = attributes["email"]?.takeIf { it.isNotEmpty() },
                emailVerified = attributes["email_verified"] == "true",
                phoneVerified = attributes["phone_number_verified"] == "true",
            )
        }
    }
}

/** The recovery-email check's question ([RecoveryContacts.promptAfterSignIn]). */
sealed interface RecoveryEmailPrompt {
    /** The account has no recovery email and nothing else recovers it. */
    data object Add : RecoveryEmailPrompt

    /** The account's recovery email is not verified yet. */
    data class Verify(
        val address: String,
    ) : RecoveryEmailPrompt
}

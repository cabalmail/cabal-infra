package com.cabalmail.kit.models

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import java.time.Instant
import java.time.OffsetDateTime
import java.time.format.DateTimeParseException

/**
 * A user of the Cognito pool, as an administrator sees it in the Users
 * screen — the counterpart of the Apple kit's `PoolUser`.
 *
 * One entry of `/list_users`' `Users` array
 * (`lambda/api/list_users/function.py`): `username`, the Cognito
 * `UserStatus`, `enabled`, `created` (Python `isoformat()`, with or without
 * fractional seconds) and `osid` (empty until the post-confirmation trigger
 * assigns one).
 */
@Serializable
data class PoolUser(
    val username: String,
    /** Cognito's `UserStatus`: `CONFIRMED`, `UNCONFIRMED`, `FORCE_CHANGE_PASSWORD`, … */
    val status: String = "",
    val enabled: Boolean = false,
    @SerialName("created") val createdText: String? = null,
    @SerialName("osid") val osidText: String? = null,
) {
    /**
     * Not yet confirmed: anything but `CONFIRMED`, as the webmail's Users view
     * groups them. An administrator can confirm such an account.
     */
    val isPending: Boolean get() = status != "CONFIRMED"

    /** When the account was created, or null if the field is absent or unreadable. */
    val created: Instant? get() = createdText?.let(::parseCreated)

    /** The mail-system user ID, or null before one is assigned. */
    val osid: String? get() = osidText?.takeIf { it.isNotEmpty() }

    private companion object {
        fun parseCreated(text: String): Instant? =
            try {
                OffsetDateTime.parse(text).toInstant()
            } catch (_: DateTimeParseException) {
                null
            }
    }
}

/**
 * One row of the per-user domain allow list (`cabal-user-domain-access`):
 * [user] may create addresses on [domain]. No row means no access, so a new
 * account can create no addresses until an administrator grants it a domain.
 */
@Serializable
data class DomainAllowance(
    val user: String,
    val domain: String,
)

/** `/list_users`. No default: a reply without the envelope is an error, not an empty pool. */
@Serializable
internal data class UsersReply(
    @SerialName("Users") val users: List<PoolUser>,
)

/** `/list_user_domain_access`. No default, for the same reason. */
@Serializable
internal data class AllowancesReply(
    @SerialName("Allowances") val allowances: List<DomainAllowance>,
)

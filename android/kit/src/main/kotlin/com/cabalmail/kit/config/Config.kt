package com.cabalmail.kit.config

import kotlinx.serialization.KSerializer
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.descriptors.PrimitiveKind
import kotlinx.serialization.descriptors.PrimitiveSerialDescriptor
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import kotlinx.serialization.json.JsonDecoder
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull

/**
 * Runtime configuration fetched from `https://{control_domain}/config.json`.
 *
 * Mirrors the JSON emitted by the Terraform-managed config object served from
 * the control-domain CloudFront distribution (see
 * `terraform/infra/modules/app/templates/config.js.tftpl`). The same object
 * backs the React app's `config.js` and the Apple client's `Configuration` —
 * sibling representations of the same values. Kotlin types are defined fresh;
 * only the wire contract is shared.
 */
@Serializable
data class Config(
    @SerialName("control_domain") val controlDomain: String,
    val domains: List<MailDomain> = emptyList(),
    val invokeUrl: String,
    @SerialName("cognitoConfig") val cognito: CognitoConfig,
    /**
     * `invitation_required`: the pool's `check_invite` trigger wants an
     * invitation code, so sign-up asks for one.
     */
    @Serializable(with = TrueOnlyWhenTrue::class)
    @SerialName("invitation_required")
    val invitationRequired: Boolean = false,
    /**
     * `sms_enabled`: the pool can send texts, so sign-up collects a phone
     * number and a code may arrive by SMS. True when the key is missing, so a
     * file older than it keeps the phone field.
     */
    @Serializable(with = FalseOnlyWhenFalse::class)
    @SerialName("sms_enabled")
    val smsEnabled: Boolean = true,
) {
    /** Base URL of the Lambda API (API Gateway invoke URL). */
    val apiUrl: String get() = invokeUrl

    /** The control-domain host serving the admin app and this config. */
    val host: String get() = controlDomain

    val cognitoUserPoolId: String get() = cognito.poolData.userPoolId

    val cognitoClientId: String get() = cognito.poolData.clientId

    /** Bare domain names the deployment hosts mail for. */
    val mailDomains: List<String> get() = domains.map { it.domain }

    /**
     * IMAP hostname derived from the control domain — the `host` value the
     * Lambda API expects on mail endpoints. Mirrors the Apple/React rule: a
     * `dev.*` control domain swaps the prefix for `imap.`, everything else
     * gets `imap.` prepended.
     */
    val imapHost: String
        get() =
            if (controlDomain.startsWith("dev.")) {
                "imap." + controlDomain.removePrefix("dev.")
            } else {
                "imap.$controlDomain"
            }
}

/**
 * One of the mail domains the deployment is authoritative for. The extra
 * fields mirror the Route 53 hosted-zone record Terraform writes into the
 * config; the client only reads [domain].
 */
@Serializable
data class MailDomain(
    val domain: String,
    val arn: String? = null,
    @SerialName("zone_id") val zoneId: String? = null,
    @SerialName("name_servers") val nameServers: List<String> = emptyList(),
)

/**
 * Cognito portion of [Config]. The wire format nests pool identifiers under a
 * `poolData` object with PascalCase keys because that is what the Cognito JS
 * SDK consumes; [Config]'s accessors normalize them for Kotlin callers.
 */
@Serializable
data class CognitoConfig(
    val region: String,
    val poolData: CognitoPool,
    val enrollClientId: String? = null,
)

@Serializable
data class CognitoPool(
    @SerialName("UserPoolId") val userPoolId: String,
    @SerialName("ClientId") val clientId: String,
)

/**
 * Reads a sign-up flag as the webmail reads it (`App.jsx`, `docs/auth.md`
 * "Client configuration"): [literal] only when the file holds exactly that
 * JSON boolean, else the other value. A missing key takes the property's
 * default, which is the same answer; a malformed one never fails the file.
 */
internal abstract class LiteralFlagSerializer(
    private val literal: Boolean,
) : KSerializer<Boolean> {
    override val descriptor: SerialDescriptor =
        PrimitiveSerialDescriptor("com.cabalmail.kit.config.LiteralFlag.$literal", PrimitiveKind.BOOLEAN)

    override fun deserialize(decoder: Decoder): Boolean {
        val element = (decoder as? JsonDecoder)?.decodeJsonElement() ?: return decoder.decodeBoolean()
        val value = (element as? JsonPrimitive)?.takeUnless { it.isString }?.booleanOrNull
        return if (value == literal) literal else !literal
    }

    override fun serialize(
        encoder: Encoder,
        value: Boolean,
    ) = encoder.encodeBoolean(value)
}

/** `invitation_required`: true only for a literal `true`. */
internal object TrueOnlyWhenTrue : LiteralFlagSerializer(true)

/** `sms_enabled`: false only for a literal `false`. */
internal object FalseOnlyWhenFalse : LiteralFlagSerializer(false)

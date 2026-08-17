package com.cabalmail.kit.config

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

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
) {
    /** Base URL of the Lambda API (API Gateway invoke URL). */
    val apiUrl: String get() = invokeUrl

    /** The control-domain host serving the admin app and this config. */
    val host: String get() = controlDomain

    val cognitoUserPoolId: String get() = cognito.poolData.userPoolId

    val cognitoClientId: String get() = cognito.poolData.clientId

    /** Bare domain names the deployment hosts mail for. */
    val mailDomains: List<String> get() = domains.map { it.domain }
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

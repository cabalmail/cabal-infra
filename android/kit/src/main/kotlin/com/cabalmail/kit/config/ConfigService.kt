package com.cabalmail.kit.config

import io.ktor.client.HttpClient
import io.ktor.client.request.get
import io.ktor.client.statement.bodyAsText
import io.ktor.http.isSuccess
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.serialization.SerializationException
import kotlinx.serialization.json.Json

/**
 * Loads and holds the runtime [Config] for a control domain.
 *
 * The control domain is the one value the user supplies — typed on the
 * sign-in form, like the Apple client's "Control domain" field, and
 * remembered per install through [ConfigCache]. Everything else — API URL,
 * Cognito pool, mail domains — comes from `https://{controlDomain}/config.json`.
 * The raw payload is cached with its domain so a relaunch can paint from the
 * last known config before (or instead of, when offline) the network refresh.
 *
 * [defaultControlDomain] is an optional build-time seed (a developer's
 * `cabalmail.controlDomain` Gradle property) used only when nothing has been
 * remembered yet; a Play/CI build passes none and the form starts empty.
 */
class ConfigService(
    private val httpClient: HttpClient,
    private val cache: ConfigCache,
    defaultControlDomain: String? = null,
) {
    private val defaultControlDomain: String? =
        defaultControlDomain?.let(::normalizeControlDomain)?.takeIf { it.isNotEmpty() }

    private val json = Json { ignoreUnknownKeys = true }

    private val mutableConfig = MutableStateFlow<Config?>(null)

    /** Latest known configuration; null until [load] or [refresh] succeeds. */
    val config: StateFlow<Config?> = mutableConfig.asStateFlow()

    private val mutableControlDomain = MutableStateFlow<String?>(null)

    /**
     * The normalized control domain [config] was loaded for; null until a
     * load succeeds. This is the host serving `config.json` (what the user
     * typed), not [Config.controlDomain], which is the deployment's bare
     * domain as reported by the server.
     */
    val controlDomain: StateFlow<String?> = mutableControlDomain.asStateFlow()

    /**
     * The control domain a session resume or a sign-in prefill should use:
     * the remembered one when a config has ever been fetched on this
     * install, else the build-time default, else null (nothing to go on —
     * the user has to type one).
     */
    suspend fun rememberedControlDomain(): String? = cache.read()?.controlDomain ?: defaultControlDomain

    /**
     * [load] for the remembered control domain. Throws [ConfigException]
     * when there is none — a signed-in session cannot exist without one, so
     * callers on the resume path treat that as "sign in again".
     */
    suspend fun load(): Config = load(rememberedControlDomain() ?: throw ConfigException(NOT_CONFIGURED))

    /**
     * Seeds [config] from the cache when the cache is for [controlDomain],
     * then refreshes from the network. A network or decode failure is
     * swallowed when the cache had a usable config for this domain (offline
     * launch) and rethrown when it did not.
     */
    suspend fun load(controlDomain: String): Config {
        val domain = normalizeControlDomain(controlDomain)
        val cached =
            cache
                .read()
                ?.takeIf { it.controlDomain == domain }
                ?.let { entry -> runCatching { json.decodeFromString<Config>(entry.raw) }.getOrNull() }
        cached?.let { publish(domain, it) }
        return try {
            refresh(domain)
        } catch (exception: Exception) {
            cached ?: throw exception
        }
    }

    /**
     * Fetches `https://{controlDomain}/config.json`, updates [config], and
     * rewrites the cache. Throws [ConfigException] on a non-2xx response or
     * an undecodable body; transport failures propagate as-is.
     */
    suspend fun refresh(controlDomain: String): Config {
        val domain = normalizeControlDomain(controlDomain)
        if (domain.isEmpty()) {
            throw ConfigException(NOT_CONFIGURED)
        }
        val configUrl = "https://$domain/config.json"
        val response = httpClient.get(configUrl)
        if (!response.status.isSuccess()) {
            throw ConfigException("Failed to fetch $configUrl: HTTP ${response.status.value}")
        }
        val raw = response.bodyAsText()
        val parsed =
            try {
                json.decodeFromString<Config>(raw)
            } catch (exception: SerializationException) {
                throw ConfigException("Could not decode config.json from $domain", exception)
            }
        cache.write(domain, raw)
        publish(domain, parsed)
        return parsed
    }

    private fun publish(
        domain: String,
        config: Config,
    ) {
        mutableControlDomain.value = domain
        mutableConfig.value = config
    }

    companion object {
        private const val NOT_CONFIGURED = "No control domain configured — sign in to choose a server"

        /**
         * Tolerates a pasted URL: strips whitespace, scheme, and trailing
         * slashes, leaving the bare host [refresh] fetches over https — a
         * plain http fetch must never leak even public config over the wire.
         */
        fun normalizeControlDomain(input: String): String =
            input
                .trim()
                .removePrefix("https://")
                .removePrefix("http://")
                .trimEnd('/')
                .lowercase()
    }
}

class ConfigException(
    message: String,
    cause: Throwable? = null,
) : Exception(message, cause)

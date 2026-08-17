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
 * The control domain is the one value baked into the build
 * (`BuildConfig.CONTROL_DOMAIN`); everything else — API URL, Cognito pool,
 * mail domains — comes from `https://{controlDomain}/config.json`. The raw
 * payload is cached through [ConfigCache] so a relaunch can paint from the
 * last known config before (or instead of, when offline) the network refresh.
 */
class ConfigService(
    controlDomain: String,
    private val httpClient: HttpClient,
    private val cache: ConfigCache,
) {
    // Tolerate a pasted URL: strip scheme and whitespace, then require https —
    // a plain http fetch must never leak even public config over the wire.
    private val configUrl: String =
        controlDomain
            .trim()
            .removePrefix("https://")
            .removePrefix("http://")
            .trimEnd('/')
            .let { host -> "https://$host/config.json" }

    private val json = Json { ignoreUnknownKeys = true }

    private val mutableConfig = MutableStateFlow<Config?>(null)

    /** Latest known configuration; null until [load] or [refresh] succeeds. */
    val config: StateFlow<Config?> = mutableConfig.asStateFlow()

    /**
     * Seeds [config] from the cache when possible, then refreshes from the
     * network. A network or decode failure is swallowed when the cache had a
     * usable config (offline launch) and rethrown when it did not.
     */
    suspend fun load(): Config {
        val cached =
            cache.read()?.let { raw ->
                runCatching { json.decodeFromString<Config>(raw) }.getOrNull()
            }
        cached?.let { mutableConfig.value = it }
        return try {
            refresh()
        } catch (exception: Exception) {
            cached ?: throw exception
        }
    }

    /**
     * Fetches `config.json`, updates [config], and rewrites the cache.
     * Throws [ConfigException] on a non-2xx response or an undecodable body.
     */
    suspend fun refresh(): Config {
        val response = httpClient.get(configUrl)
        if (!response.status.isSuccess()) {
            throw ConfigException("Failed to fetch $configUrl: HTTP ${response.status.value}")
        }
        val raw = response.bodyAsText()
        val parsed =
            try {
                json.decodeFromString<Config>(raw)
            } catch (exception: SerializationException) {
                throw ConfigException("Could not decode config.json", exception)
            }
        cache.write(raw)
        mutableConfig.value = parsed
        return parsed
    }
}

class ConfigException(
    message: String,
    cause: Throwable? = null,
) : Exception(message, cause)

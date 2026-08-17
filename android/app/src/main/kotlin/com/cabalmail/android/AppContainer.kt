package com.cabalmail.android

import android.content.Context
import androidx.datastore.preferences.preferencesDataStore
import com.cabalmail.kit.api.ApiClient
import com.cabalmail.kit.auth.AuthService
import com.cabalmail.kit.auth.CognitoAuthService
import com.cabalmail.kit.auth.EncryptedTokenStore
import com.cabalmail.kit.auth.TokenStore
import com.cabalmail.kit.cache.AddressRepository
import com.cabalmail.kit.cache.BodyCache
import com.cabalmail.kit.cache.EnvelopeCache
import com.cabalmail.kit.cache.RoomEnvelopeCache
import com.cabalmail.kit.config.Config
import com.cabalmail.kit.config.ConfigService
import com.cabalmail.kit.config.DataStoreConfigCache
import io.ktor.client.HttpClient
import io.ktor.client.engine.okhttp.OkHttp
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.io.File

private val Context.configDataStore by preferencesDataStore(name = "config")

/**
 * Manual constructor-injection graph (the plan's DI decision: no Hilt until
 * wiring hurts). One instance, owned by [CabalmailApp].
 *
 * [AuthService] construction is deferred behind [requireAuth] because it
 * needs the Cognito pool coordinates from `config.json`; everything after
 * the first successful [ConfigService.load] is memoized.
 */
class AppContainer(
    context: Context,
) {
    private val appContext = context.applicationContext

    val httpClient: HttpClient = HttpClient(OkHttp)

    val configService: ConfigService =
        ConfigService(
            controlDomain = BuildConfig.CONTROL_DOMAIN,
            httpClient = httpClient,
            cache = DataStoreConfigCache(appContext.configDataStore),
        )

    val tokenStore: TokenStore by lazy { EncryptedTokenStore(appContext) }

    val envelopeCache: EnvelopeCache by lazy {
        RoomEnvelopeCache.open(appContext)
    }

    val bodyCache: BodyCache by lazy {
        BodyCache(File(appContext.filesDir, "body-cache"))
    }

    private val authMutex = Mutex()
    private var authService: AuthService? = null
    private var apiClient: ApiClient? = null
    private var addressRepository: AddressRepository? = null

    /**
     * The auth service, constructing it from the loaded config on first
     * use. Suspends on the config fetch when neither cache nor network has
     * produced a config yet.
     */
    suspend fun requireAuth(): AuthService =
        authMutex.withLock {
            authService ?: run {
                val config: Config = configService.config.value ?: configService.load()
                CognitoAuthService(
                    clientId = config.cognitoClientId,
                    region = config.cognito.region,
                    httpClient = httpClient,
                    tokenStore = tokenStore,
                ).also { authService = it }
            }
        }

    /** The Lambda API client; same config-deferred construction as auth. */
    suspend fun requireApi(): ApiClient {
        val auth = requireAuth()
        return authMutex.withLock {
            apiClient ?: run {
                val config: Config = configService.config.value ?: configService.load()
                ApiClient(
                    baseUrl = config.apiUrl,
                    host = config.imapHost,
                    authService = auth,
                    httpClient = httpClient,
                ).also { apiClient = it }
            }
        }
    }

    suspend fun requireAddressRepository(): AddressRepository {
        val api = requireApi()
        return authMutex.withLock {
            addressRepository ?: AddressRepository(api).also { addressRepository = it }
        }
    }
}

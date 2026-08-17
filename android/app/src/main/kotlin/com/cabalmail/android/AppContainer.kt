package com.cabalmail.android

import android.content.Context
import androidx.datastore.preferences.preferencesDataStore
import com.cabalmail.kit.auth.AuthService
import com.cabalmail.kit.auth.CognitoAuthService
import com.cabalmail.kit.auth.EncryptedTokenStore
import com.cabalmail.kit.auth.TokenStore
import com.cabalmail.kit.config.Config
import com.cabalmail.kit.config.ConfigService
import com.cabalmail.kit.config.DataStoreConfigCache
import io.ktor.client.HttpClient
import io.ktor.client.engine.okhttp.OkHttp
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

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

    private val authMutex = Mutex()
    private var authService: AuthService? = null

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
}

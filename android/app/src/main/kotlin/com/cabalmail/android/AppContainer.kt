package com.cabalmail.android

import android.content.Context
import androidx.datastore.preferences.preferencesDataStore
import com.cabalmail.android.navigation.NavCursor
import com.cabalmail.android.ui.compose.ShareIntake
import com.cabalmail.kit.api.ApiClient
import com.cabalmail.kit.auth.AuthService
import com.cabalmail.kit.auth.CognitoAuthService
import com.cabalmail.kit.auth.EncryptedTokenStore
import com.cabalmail.kit.auth.TokenStore
import com.cabalmail.kit.cache.AddressRepository
import com.cabalmail.kit.cache.BimiRepository
import com.cabalmail.kit.cache.BodyCache
import com.cabalmail.kit.cache.DraftStore
import com.cabalmail.kit.cache.EnvelopeCache
import com.cabalmail.kit.cache.RecipientHistory
import com.cabalmail.kit.cache.RoomEnvelopeCache
import com.cabalmail.kit.config.Config
import com.cabalmail.kit.config.ConfigService
import com.cabalmail.kit.config.DataStoreConfigCache
import com.cabalmail.kit.settings.PreferencesRepository
import io.ktor.client.HttpClient
import io.ktor.client.engine.okhttp.OkHttp
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.io.File

private val Context.configDataStore by preferencesDataStore(name = "config")

// Per-install navigation identity (resume cursor); never backed up.
private val Context.navDataStore by preferencesDataStore(name = "nav")

// Local cache of the user's preferences (plan §6.3); the synced subset is
// re-pulled from the server on every launch.
private val Context.settingsDataStore by preferencesDataStore(name = "settings")

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

    /** For ContentResolver work (share intake, attachment import). */
    val applicationContext: Context get() = appContext

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

    /** Downloaded-attachment scratch space, served through the FileProvider. */
    val attachmentDir: File by lazy {
        File(appContext.cacheDir, "attachments").apply { mkdirs() }
    }

    /**
     * The local draft buffer (plan §5.3) — internal storage, so attachment
     * copies and half-written mail never leave the sandbox.
     */
    val draftStore: DraftStore by lazy {
        DraftStore(File(appContext.filesDir, "drafts"))
    }

    /** Learned recipient list for compose autocomplete. */
    val recipientHistory: RecipientHistory by lazy {
        RecipientHistory(File(appContext.filesDir, "recipients.json"))
    }

    /** Content shared into the app (ACTION_SEND) awaiting a compose screen. */
    val shareIntake = ShareIntake()

    /**
     * App-lifetime work that outlives any one screen: nav-cursor pushes, and
     * the close-without-send draft save that must finish after the compose
     * screen's own scope is gone.
     */
    val appScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    /** Preferences: DataStore cache + server sync (plan §6.3). */
    val preferences: PreferencesRepository by lazy {
        PreferencesRepository(appContext.settingsDataStore, appScope) { requireApi() }
    }

    val navCursor: NavCursor by lazy {
        NavCursor(appContext.navDataStore, appScope) { requireApi() }
    }

    /** BIMI lookups for avatar rows; safe before sign-in resolves (null). */
    val bimiLookup: suspend (String) -> String? = { domain ->
        runCatching { requireBimi().logoUrl(domain) }.getOrNull()
    }

    private val authMutex = Mutex()
    private var authService: AuthService? = null
    private var apiClient: ApiClient? = null
    private var addressRepository: AddressRepository? = null
    private var bimiRepository: BimiRepository? = null

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

    suspend fun requireBimi(): BimiRepository {
        val api = requireApi()
        return authMutex.withLock {
            bimiRepository ?: BimiRepository(api).also { bimiRepository = it }
        }
    }
}

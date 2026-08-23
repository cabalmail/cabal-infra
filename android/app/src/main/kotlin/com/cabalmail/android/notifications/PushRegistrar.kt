package com.cabalmail.android.notifications

import android.util.Log
import com.cabalmail.android.AppContainer
import com.cabalmail.android.BuildConfig
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.util.Locale

/**
 * Registration lifecycle for push (docs/1.x/android-push-notifications.md):
 * an idempotent `/push_register` upsert asserted on every launch and on
 * token rotation, and a best-effort `/push_deregister` on sign-out or when
 * the user turns notifications off. Everything here is a quiet no-op when
 * the build has no Firebase config, the device has no Play services, the
 * user has not opted in, or no session exists — the WorkManager poll is
 * the notification path in all of those states.
 */
object PushRegistrar {
    private const val TAG = "cabal-push"

    /** Registers this device if push is available and the user opted in. */
    suspend fun register(container: AppContainer) =
        withContext(Dispatchers.Default) {
            if (!Push.available(container.applicationContext)) {
                return@withContext
            }
            if (!container.preferences.current().notificationsEnabled) {
                return@withContext
            }
            if (container.tokenStore.readTokens() == null) {
                return@withContext
            }
            val token = Push.currentToken() ?: return@withContext
            registerToken(container, token)
        }

    /** The upsert itself; also the rotation path (onNewToken). */
    suspend fun registerToken(
        container: AppContainer,
        token: String,
    ) {
        runCatching {
            container.requireApi().pushRegister(
                deviceToken = token,
                bundleId = BuildConfig.APPLICATION_ID,
                appVersion = BuildConfig.VERSION_NAME,
                locale = Locale.getDefault().toLanguageTag(),
            )
        }.onFailure { Log.w(TAG, "push registration failed; will retry next launch", it) }
    }

    /**
     * Removes the server row, then invalidates the local token. Both legs
     * are best-effort — sign-out must proceed regardless, and the
     * dispatcher prunes rows for dead tokens on its own. Call this while
     * the session is still live: `/push_deregister` needs a valid ID token.
     */
    suspend fun deregister(container: AppContainer) =
        withContext(Dispatchers.Default) {
            if (!Push.available(container.applicationContext)) {
                return@withContext
            }
            val token = Push.currentToken()
            if (token != null) {
                runCatching { container.requireApi().pushDeregister(token) }
                    .onFailure { Log.w(TAG, "push deregistration failed; dispatcher will prune", it) }
            }
            runCatching { Push.deleteToken() }
        }
}

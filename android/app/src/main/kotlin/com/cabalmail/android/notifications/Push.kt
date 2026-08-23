package com.cabalmail.android.notifications

import android.content.Context
import com.cabalmail.android.BuildConfig
import com.google.android.gms.common.ConnectionResult
import com.google.android.gms.common.GoogleApiAvailability
import com.google.firebase.FirebaseApp
import com.google.firebase.FirebaseOptions
import com.google.firebase.messaging.FirebaseMessaging
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlin.coroutines.resume

/**
 * Firebase wiring for push (docs/1.x/android-push-notifications.md). There
 * is deliberately no google-services plugin and no google-services.json:
 * the per-environment client config arrives as `cabalmail.fcm*` gradle
 * properties (see app/build.gradle.kts), and all-blank — the default, and
 * what CI builds — leaves push wired off with the WorkManager poll carrying
 * notifications instead.
 */
object Push {
    /** True when the build carries a complete Firebase client config. */
    val configured: Boolean =
        BuildConfig.FCM_PROJECT_ID.isNotEmpty() &&
            BuildConfig.FCM_APPLICATION_ID.isNotEmpty() &&
            BuildConfig.FCM_API_KEY.isNotEmpty() &&
            BuildConfig.FCM_SENDER_ID.isNotEmpty()

    /** True when this device can actually receive FCM messages. */
    fun available(context: Context): Boolean =
        configured &&
            GoogleApiAvailability
                .getInstance()
                .isGooglePlayServicesAvailable(context) == ConnectionResult.SUCCESS

    /**
     * Initializes the default FirebaseApp from BuildConfig, once. Safe (and
     * a no-op) when unconfigured; called from Application.onCreate so the
     * messaging service always finds an initialized app when a message
     * wakes the process.
     */
    fun initialize(context: Context) {
        if (!configured || FirebaseApp.getApps(context).isNotEmpty()) {
            return
        }
        FirebaseApp.initializeApp(
            context,
            FirebaseOptions
                .Builder()
                .setProjectId(BuildConfig.FCM_PROJECT_ID)
                .setApplicationId(BuildConfig.FCM_APPLICATION_ID)
                .setApiKey(BuildConfig.FCM_API_KEY)
                .setGcmSenderId(BuildConfig.FCM_SENDER_ID)
                .build(),
        )
    }

    /**
     * This device's FCM registration token, minting one on first call —
     * which is why callers gate on the notifications opt-in first. Null on
     * any failure (offline, Play services degraded); registration retries
     * on the next launch.
     */
    suspend fun currentToken(): String? =
        suspendCancellableCoroutine { continuation ->
            FirebaseMessaging.getInstance().token.addOnCompleteListener { task ->
                continuation.resume(if (task.isSuccessful) task.result else null)
            }
        }

    /** Invalidates the local token so delivery stops entirely (sign-out). */
    suspend fun deleteToken() {
        suspendCancellableCoroutine { continuation ->
            FirebaseMessaging.getInstance().deleteToken().addOnCompleteListener {
                continuation.resume(Unit)
            }
        }
    }
}

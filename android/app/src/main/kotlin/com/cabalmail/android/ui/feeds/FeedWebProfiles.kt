package com.cabalmail.android.ui.feeds

import android.content.Context
import android.os.Handler
import android.os.Looper
import androidx.webkit.ProfileStore
import androidx.webkit.WebViewFeature

/**
 * The per-subscription web profiles (D11). When a subscription departs
 * the catalog, its cookies and storage go with it: the profile's cookies
 * are cleared first, then the profile deleted, so a delete that fails
 * (a web view still holds it) leaves nothing behind. A no-op where the
 * installed WebView lacks the multi-profile feature.
 */
object FeedWebProfiles {
    fun drop(
        context: Context,
        profileNames: List<String>,
    ) {
        if (profileNames.isEmpty() || !WebViewFeature.isFeatureSupported(WebViewFeature.MULTI_PROFILE)) return
        // The profile store must be touched on the main thread.
        Handler(Looper.getMainLooper()).post {
            runCatching {
                val store = ProfileStore.getInstance()
                profileNames.filter { it.isNotEmpty() }.forEach { name ->
                    runCatching { store.getProfile(name)?.cookieManager?.removeAllCookies(null) }
                    runCatching { store.deleteProfile(name) }
                }
            }
        }
    }
}

package com.cabalmail.android.notifications

import com.cabalmail.android.CabalmailApp
import com.cabalmail.android.MailEvent
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeoutOrNull

/**
 * Receives content-free FCM wake signals and turns them into enriched
 * local notifications (docs/1.x/android-push-notifications.md). This is
 * the Apple NSE dance without the extension: fetch sender/subject from
 * `/push_envelope` with the user's own JWT, post locally — message content
 * never transits Google. Enrichment failure degrades to the generic "New
 * mail" alert; nothing is dropped silently.
 */
class PushMessagingService : FirebaseMessagingService() {
    override fun onNewToken(token: String) {
        val container = (applicationContext as CabalmailApp).container
        container.appScope.launch {
            if (container.preferences.current().notificationsEnabled &&
                container.tokenStore.readTokens() != null
            ) {
                PushRegistrar.registerToken(container, token)
            }
        }
    }

    override fun onMessageReceived(message: RemoteMessage) {
        val signal = PushSignal.from(message.data) ?: return
        val container = (applicationContext as CabalmailApp).container
        if (container.tokenStore.readTokens() == null) {
            return
        }
        // FCM delivers on a background thread with a short execution budget;
        // one blocking enrichment round trip fits comfortably inside it.
        runBlocking {
            if (!container.preferences.current().notificationsEnabled) {
                return@runBlocking
            }
            if (AppForeground.isForeground) {
                // Foreground suppression, matching the Apple clients: the
                // visible list updating is the notification. Dropped when no
                // list for this folder is subscribed — the 60s foreground
                // poll covers that case.
                container.mailEvents.emit(MailEvent.Reconcile(signal.folder))
                return@runBlocking
            }
            if (!NewMailSync.canPost(this@PushMessagingService)) {
                return@runBlocking
            }
            val envelope =
                withTimeoutOrNull(ENRICH_TIMEOUT_MS) {
                    runCatching {
                        container.requireApi().pushEnvelope(signal.folder, signal.uid, signal.msgId)
                    }.getOrNull()
                }
            NewMailSync.postPush(this@PushMessagingService, signal, envelope)
        }
    }

    private companion object {
        // Under FCM's ~10s budget with margin for the notification post.
        const val ENRICH_TIMEOUT_MS = 8_000L
    }
}

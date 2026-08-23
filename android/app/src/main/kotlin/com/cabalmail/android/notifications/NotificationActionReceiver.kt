package com.cabalmail.android.notifications

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import androidx.core.app.NotificationManagerCompat

/**
 * Handles Mark as read / Archive taps on a new-mail notification. The
 * notification is dismissed optimistically and the server operation runs
 * (with retry) in a WorkManager one-shot — a tap must never block on the
 * network, and a transient failure must still land eventually, like the
 * Apple clients' background action handlers.
 */
class NotificationActionReceiver : BroadcastReceiver() {
    override fun onReceive(
        context: Context,
        intent: Intent,
    ) {
        val action =
            NotificationAction.fromValues(
                verb = intent.action?.removePrefix(ACTION_PREFIX),
                folder = intent.getStringExtra(EXTRA_FOLDER),
                uid = intent.getLongExtra(EXTRA_UID, 0),
                notificationId = intent.getIntExtra(EXTRA_NOTIFICATION_ID, 0),
            ) ?: return
        NotificationManagerCompat.from(context).cancel(action.notificationId)
        NotificationActionWorker.enqueue(context, action)
    }

    companion object {
        private const val ACTION_PREFIX = "com.cabalmail.android.NOTIFICATION_ACTION_"
        private const val EXTRA_FOLDER = "com.cabalmail.android.ACTION_FOLDER"
        private const val EXTRA_UID = "com.cabalmail.android.ACTION_UID"
        private const val EXTRA_NOTIFICATION_ID = "com.cabalmail.android.ACTION_NOTIFICATION_ID"

        /**
         * A broadcast PendingIntent for one verb on one message. The verb
         * rides in the intent action (extras alone would not distinguish
         * PendingIntents — filterEquals ignores them) and the request code
         * is the notification id, so per-message intents stay distinct and
         * a redelivered signal's UPDATE_CURRENT refreshes the extras.
         */
        fun pendingIntent(
            context: Context,
            verb: NotificationAction.Verb,
            folder: String,
            uid: Long,
            notificationId: Int,
        ): PendingIntent =
            PendingIntent.getBroadcast(
                context,
                notificationId,
                Intent(context, NotificationActionReceiver::class.java)
                    .setAction(ACTION_PREFIX + verb.name)
                    .putExtra(EXTRA_FOLDER, folder)
                    .putExtra(EXTRA_UID, uid)
                    .putExtra(EXTRA_NOTIFICATION_ID, notificationId),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
    }
}

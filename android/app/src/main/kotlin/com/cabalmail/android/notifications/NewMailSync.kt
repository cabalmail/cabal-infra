package com.cabalmail.android.notifications

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import androidx.core.content.edit
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.NetworkType
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import com.cabalmail.android.CabalmailApp
import com.cabalmail.android.MainActivity
import com.cabalmail.android.R
import com.cabalmail.kit.models.Envelope
import com.cabalmail.kit.models.mailboxDisplayName
import java.util.concurrent.TimeUnit

/**
 * Background new-mail sync (plan §7.3): a WorkManager periodic job at the
 * 15-minute floor opens a short API session, STATUSes INBOX, and posts one
 * local notification per message that arrived since the last check.
 * Local only — no FCM yet. Off until the user opts in from Settings, which
 * also asks for the notification permission on API 33+.
 */
object NewMailSync {
    const val CHANNEL_ID = "new_mail"
    const val WORK_NAME = "new-mail-sync"
    const val EXTRA_FOLDER = "com.cabalmail.android.OPEN_FOLDER"
    const val EXTRA_UID = "com.cabalmail.android.OPEN_UID"
    private const val PREFS = "newmail"
    private const val KEY_LAST_UID_NEXT = "last_uid_next"
    private const val INBOX = "INBOX"
    private const val PER_TICK_CAP = 20
    private const val GROUP = "com.cabalmail.android.NEW_MAIL"
    private const val SUMMARY_ID = 0

    fun schedule(
        context: Context,
        enabled: Boolean,
    ) {
        val manager = WorkManager.getInstance(context)
        if (!enabled) {
            manager.cancelUniqueWork(WORK_NAME)
            return
        }
        ensureChannel(context)
        val request =
            PeriodicWorkRequestBuilder<NewMailWorker>(15, TimeUnit.MINUTES)
                .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build())
                .build()
        manager.enqueueUniquePeriodicWork(WORK_NAME, ExistingPeriodicWorkPolicy.KEEP, request)
    }

    fun ensureChannel(context: Context) {
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (manager.getNotificationChannel(CHANNEL_ID) == null) {
            manager.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID,
                    context.getString(R.string.notification_channel_new_mail),
                    NotificationManager.IMPORTANCE_DEFAULT,
                ),
            )
        }
    }

    fun canPost(context: Context): Boolean =
        NotificationManagerCompat.from(context).areNotificationsEnabled() &&
            (
                Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
                    ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) ==
                    PackageManager.PERMISSION_GRANTED
            )

    /** Records the current watermark so the first enabled tick posts nothing. */
    fun baseline(
        context: Context,
        uidNext: Long,
    ) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit { putLong(KEY_LAST_UID_NEXT, uidNext) }
    }

    fun clearBaseline(context: Context) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit { remove(KEY_LAST_UID_NEXT) }
    }

    class NewMailWorker(
        context: Context,
        params: WorkerParameters,
    ) : CoroutineWorker(context, params) {
        override suspend fun doWork(): Result {
            val context = applicationContext
            val container = (context as CabalmailApp).container
            if (!container.preferences.current().notificationsEnabled || container.tokenStore.readTokens() == null) {
                return Result.success()
            }
            val api = runCatching { container.requireApi() }.getOrElse { return Result.retry() }
            val status = runCatching { api.folderStatus(INBOX) }.getOrElse { return Result.retry() }
            val uidNext = status.uidNext ?: return Result.success()
            val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val last = prefs.getLong(KEY_LAST_UID_NEXT, -1L)
            if (last < 0) {
                // First run: set the watermark; nothing before it is "new".
                prefs.edit { putLong(KEY_LAST_UID_NEXT, uidNext) }
                return Result.success()
            }
            if (uidNext > last && canPost(context)) {
                val page =
                    runCatching {
                        api.listMessages(
                            INBOX,
                            "ARRIVAL",
                            true,
                            0,
                            PER_TICK_CAP,
                        )
                    }.getOrElse { return Result.retry() }
                val newUids = page.messageIds.filter { it >= last }
                if (newUids.isNotEmpty()) {
                    val envelopes =
                        runCatching { api.listEnvelopes(INBOX, newUids) }.getOrElse { return Result.retry() }
                    post(context, envelopes.values.sortedBy { it.id })
                }
            }
            prefs.edit { putLong(KEY_LAST_UID_NEXT, uidNext) }
            return Result.success()
        }

        private fun post(
            context: Context,
            envelopes: List<Envelope>,
        ) {
            ensureChannel(context)
            val manager = NotificationManagerCompat.from(context)
            // Lint's permission check: the worker only gets here after
            // canPost() (which checks POST_NOTIFICATIONS on API 33+), but
            // the framework check is what the analyzer recognizes.
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
                ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) !=
                PackageManager.PERMISSION_GRANTED
            ) {
                return
            }
            envelopes.forEach { envelope ->
                val sender = envelope.from.firstOrNull()?.let { mailboxDisplayName(it) } ?: ""
                val open =
                    Intent(context, MainActivity::class.java)
                        .setAction(Intent.ACTION_VIEW)
                        .putExtra(EXTRA_FOLDER, INBOX)
                        .putExtra(EXTRA_UID, envelope.id)
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                val pending =
                    PendingIntent.getActivity(
                        context,
                        envelope.id.toInt(),
                        open,
                        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                    )
                val notification =
                    NotificationCompat
                        .Builder(context, CHANNEL_ID)
                        .setSmallIcon(R.drawable.ic_notification)
                        .setContentTitle(sender.ifBlank { context.getString(R.string.notification_new_mail) })
                        .setContentText(envelope.subject.ifBlank { context.getString(R.string.no_subject) })
                        .setContentIntent(pending)
                        .setAutoCancel(true)
                        .setGroup(GROUP)
                        .setCategory(NotificationCompat.CATEGORY_EMAIL)
                        .build()
                manager.notify(envelope.id.toInt(), notification)
            }
            if (envelopes.size > 1) {
                val summary =
                    NotificationCompat
                        .Builder(context, CHANNEL_ID)
                        .setSmallIcon(R.drawable.ic_notification)
                        .setContentTitle(context.getString(R.string.notification_new_mail))
                        .setContentText(
                            context.resources.getQuantityString(
                                R.plurals.notification_new_count,
                                envelopes.size,
                                envelopes.size,
                            ),
                        ).setGroup(GROUP)
                        .setGroupSummary(true)
                        .setAutoCancel(true)
                        .build()
                manager.notify(SUMMARY_ID, summary)
            }
        }
    }
}

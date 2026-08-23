package com.cabalmail.android.notifications

import android.content.Context
import android.util.Log
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.Data
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import com.cabalmail.android.CabalmailApp
import com.cabalmail.android.MailEvent
import com.cabalmail.android.ui.mail.MessageListViewModel

/**
 * Executes one notification action against the API, retrying on transient
 * failure. Mark as read sets `\Seen`; Archive moves to the auto-created
 * Archive mailbox (the same hardcoded destination the in-app dispose
 * action uses — see the plan erratum for why there is no folder
 * discovery). Best-effort with a bounded retry: the notification is
 * already dismissed, and the mail itself is never at risk.
 */
class NotificationActionWorker(
    context: Context,
    parameters: WorkerParameters,
) : CoroutineWorker(context, parameters) {
    override suspend fun doWork(): Result {
        val action =
            NotificationAction.fromValues(
                verb = inputData.getString(KEY_VERB),
                folder = inputData.getString(KEY_FOLDER),
                uid = inputData.getLong(KEY_UID, 0),
                notificationId = inputData.getInt(KEY_NOTIFICATION_ID, 0),
            ) ?: return Result.failure()
        val container = (applicationContext as CabalmailApp).container
        if (container.tokenStore.readTokens() == null) {
            // Signed out since the tap; nothing to act as.
            return Result.success()
        }
        return runCatching {
            val api = container.requireApi()
            when (action.verb) {
                NotificationAction.Verb.MARK_READ ->
                    api.setFlag(action.folder, listOf(action.uid), "\\Seen", set = true)
                NotificationAction.Verb.ARCHIVE ->
                    api.moveMessages(
                        source = action.folder,
                        destination = MessageListViewModel.ARCHIVE_FOLDER,
                        ids = listOf(action.uid),
                        markSeen = true,
                    )
            }
        }.fold(
            onSuccess = {
                // A foregrounded app refreshes the affected folder; a dead
                // process just drops the emit.
                container.mailEvents.emit(MailEvent.Reconcile(action.folder))
                Result.success()
            },
            onFailure = { error ->
                if (runAttemptCount >= MAX_ATTEMPTS - 1) {
                    Log.w(TAG, "notification action ${action.verb} gave up", error)
                    Result.failure()
                } else {
                    Result.retry()
                }
            },
        )
    }

    companion object {
        private const val TAG = "cabal-push"
        private const val KEY_VERB = "verb"
        private const val KEY_FOLDER = "folder"
        private const val KEY_UID = "uid"
        private const val KEY_NOTIFICATION_ID = "notification_id"
        private const val MAX_ATTEMPTS = 3

        fun enqueue(
            context: Context,
            action: NotificationAction,
        ) {
            val request =
                OneTimeWorkRequestBuilder<NotificationActionWorker>()
                    .setConstraints(
                        Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build(),
                    ).setInputData(
                        Data
                            .Builder()
                            .putString(KEY_VERB, action.verb.name)
                            .putString(KEY_FOLDER, action.folder)
                            .putLong(KEY_UID, action.uid)
                            .putInt(KEY_NOTIFICATION_ID, action.notificationId)
                            .build(),
                    ).build()
            // KEEP: a double-tap on the same action must not run it twice.
            WorkManager.getInstance(context).enqueueUniqueWork(
                "notification-action-${action.verb}-${action.folder}-${action.uid}",
                ExistingWorkPolicy.KEEP,
                request,
            )
        }
    }
}

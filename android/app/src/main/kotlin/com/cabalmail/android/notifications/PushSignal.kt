package com.cabalmail.android.notifications

/**
 * A parsed FCM wake signal (docs/1.x/android-push-notifications.md). The
 * data message is content-free by design — folder, a best-effort UID hint,
 * and the Message-ID; sender/subject arrive only via on-device enrichment.
 */
data class PushSignal(
    val folder: String,
    /** UID hint; null when procmail enqueued before Dovecot assigned one. */
    val uid: Long?,
    val msgId: String?,
) {
    companion object {
        /**
         * Parses an FCM data map, or null when the signal cannot identify a
         * message (no folder, or neither a positive UID nor a Message-ID).
         */
        fun from(data: Map<String, String>): PushSignal? {
            val folder = data["folder"]?.trim().orEmpty()
            if (folder.isEmpty()) {
                return null
            }
            val uid = data["uid"]?.toLongOrNull()?.takeIf { it > 0 }
            val msgId = data["msg_id"]?.takeIf { it.isNotBlank() }
            if (uid == null && msgId == null) {
                return null
            }
            return PushSignal(folder, uid, msgId)
        }
    }
}

/**
 * Stable notification id for a wake signal, so a redelivered signal
 * replaces — never stacks on — the notification it already produced (the
 * dispatcher sends no FCM collapse key; this is the dedup). Prefers the
 * server-resolved UID, matching the poller's UID-keyed ids so the two
 * paths also dedup against each other.
 */
internal fun pushNotificationId(
    signal: PushSignal,
    resolvedUid: Long?,
): Int {
    val uid = resolvedUid?.takeIf { it > 0 } ?: signal.uid
    return uid?.toInt() ?: signal.msgId.hashCode()
}

package com.cabalmail.android.notifications

/**
 * One actionable verb on a new-mail notification (plan phase 5, mirroring
 * the Apple clients' category actions). Pure model + validation, so the
 * intent round-trip and the eligibility rules are unit-tested without
 * Android.
 */
data class NotificationAction(
    val verb: Verb,
    val folder: String,
    val uid: Long,
    val notificationId: Int,
) {
    enum class Verb {
        MARK_READ,
        ARCHIVE,
    }

    companion object {
        /** Validates raw intent/worker values; null when unactionable. */
        fun fromValues(
            verb: String?,
            folder: String?,
            uid: Long,
            notificationId: Int,
        ): NotificationAction? {
            val parsed = Verb.entries.firstOrNull { it.name == verb } ?: return null
            if (folder.isNullOrBlank() || uid <= 0) {
                return null
            }
            return NotificationAction(parsed, folder, uid, notificationId)
        }

        /**
         * Which verbs a notification offers: none without a resolved UID
         * (nothing to act on), and no Archive when the mail already sits
         * in the archive folder — matching the in-app dispose behavior.
         */
        fun eligible(
            folder: String,
            uid: Long,
            archiveFolder: String,
        ): List<Verb> =
            when {
                uid <= 0 -> emptyList()
                folder.equals(archiveFolder, ignoreCase = true) -> listOf(Verb.MARK_READ)
                else -> listOf(Verb.MARK_READ, Verb.ARCHIVE)
            }
    }
}

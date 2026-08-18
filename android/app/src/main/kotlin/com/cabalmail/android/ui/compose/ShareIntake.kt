package com.cabalmail.android.ui.compose

import android.content.Intent
import android.net.Uri
import android.os.Build
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.getAndUpdate

/** Content another app shared into Cabalmail (plan §5.4). */
data class SharedContent(
    val text: String? = null,
    val subject: String? = null,
    val uris: List<Uri> = emptyList(),
) {
    val isEmpty: Boolean get() = text.isNullOrBlank() && subject.isNullOrBlank() && uris.isEmpty()
}

/**
 * Hands an `ACTION_SEND` / `ACTION_SEND_MULTIPLE` intent from the activity
 * to whichever navigation host is (or becomes) visible. Held app-wide so a
 * share that arrives while the sign-in screen is up is honoured once the
 * user is in.
 */
class ShareIntake {
    private val mutablePending = MutableStateFlow<SharedContent?>(null)
    val pending: StateFlow<SharedContent?> = mutablePending.asStateFlow()

    /** Parses [intent]; returns true when it carried something to compose. */
    fun offer(intent: Intent?): Boolean {
        val content = parse(intent) ?: return false
        mutablePending.value = content
        return true
    }

    /** Takes the pending share, if any, so it is composed exactly once. */
    fun consume(): SharedContent? = mutablePending.getAndUpdate { null }

    private fun parse(intent: Intent?): SharedContent? {
        intent ?: return null
        val uris: List<Uri> =
            when (intent.action) {
                Intent.ACTION_SEND -> listOfNotNull(intent.parcelable(Intent.EXTRA_STREAM))
                Intent.ACTION_SEND_MULTIPLE -> intent.parcelableList(Intent.EXTRA_STREAM)
                else -> return null
            }
        val content =
            SharedContent(
                text = intent.getStringExtra(Intent.EXTRA_TEXT),
                subject = intent.getStringExtra(Intent.EXTRA_SUBJECT),
                uris = uris,
            )
        return content.takeUnless { it.isEmpty }
    }

    @Suppress("DEPRECATION")
    private fun Intent.parcelable(key: String): Uri? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            getParcelableExtra(key, Uri::class.java)
        } else {
            getParcelableExtra(key)
        }

    @Suppress("DEPRECATION")
    private fun Intent.parcelableList(key: String): List<Uri> =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            getParcelableArrayListExtra(key, Uri::class.java).orEmpty()
        } else {
            getParcelableArrayListExtra<Uri>(key).orEmpty()
        }
}

/** A message a notification tap asked to open (plan §7.3). */
data class OpenRequest(
    val folder: String,
    val uid: Long,
)

/** Same hand-off pattern as [ShareIntake], for notification taps. */
class OpenIntake {
    private val mutablePending = MutableStateFlow<OpenRequest?>(null)
    val pending: StateFlow<OpenRequest?> = mutablePending.asStateFlow()

    fun offer(intent: Intent?): Boolean {
        intent ?: return false
        val folder = intent.getStringExtra(com.cabalmail.android.notifications.NewMailSync.EXTRA_FOLDER) ?: return false
        val uid = intent.getLongExtra(com.cabalmail.android.notifications.NewMailSync.EXTRA_UID, -1L)
        if (uid <= 0) {
            return false
        }
        mutablePending.value = OpenRequest(folder, uid)
        return true
    }

    fun consume(): OpenRequest? = mutablePending.getAndUpdate { null }
}

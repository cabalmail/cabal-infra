package com.cabalmail.android.ui.mail

import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.rememberUpdatedState
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.repeatOnLifecycle
import kotlinx.coroutines.delay

/**
 * Foreground polling (plan §7.3): calls [onPoll] every [intervalMs] while
 * the host is RESUMED, and stops the moment it is not — no IDLE over the
 * API, so this is how visible lists notice new mail.
 */
@Composable
fun ForegroundPolling(
    onPoll: () -> Unit,
    intervalMs: Long = FOREGROUND_POLL_MS,
) {
    val owner = LocalLifecycleOwner.current
    val current by rememberUpdatedState(onPoll)
    LaunchedEffect(owner, intervalMs) {
        owner.lifecycle.repeatOnLifecycle(Lifecycle.State.RESUMED) {
            while (true) {
                delay(intervalMs)
                current()
            }
        }
    }
}

const val FOREGROUND_POLL_MS = 60_000L

package com.cabalmail.android

import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.asSharedFlow

/**
 * Cross-screen mail mutations, so a change made in the reader (or a
 * side-by-side pane) is reflected in the list without a refetch.
 */
sealed interface MailEvent {
    val folder: String

    /** One flag was set/cleared on [uids] in [folder]. */
    data class FlagChanged(
        override val folder: String,
        val uids: Set<Long>,
        val flag: String,
        val value: Boolean,
    ) : MailEvent

    /** [uids] left [folder] (moved, disposed, purged). */
    data class Removed(
        override val folder: String,
        val uids: Set<Long>,
    ) : MailEvent
}

class MailEventBus {
    private val mutable = MutableSharedFlow<MailEvent>(extraBufferCapacity = 16)
    val events: SharedFlow<MailEvent> = mutable.asSharedFlow()

    fun emit(event: MailEvent) {
        mutable.tryEmit(event)
    }
}

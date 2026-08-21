package com.cabalmail.android

import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.asSharedFlow
import java.util.concurrent.atomic.AtomicInteger

/**
 * Cross-screen mail mutations, so a change made in the reader (or a
 * side-by-side pane) is reflected in the list without a refetch. Emitters
 * apply their change optimistically, so an event may precede the server's
 * confirmation; [MailEvent.Reconcile] is the failure signal.
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

    /**
     * An optimistically applied mutation against [folder] failed
     * server-side; viewers of the folder should refetch true state.
     */
    data class Reconcile(
        override val folder: String,
    ) : MailEvent
}

class MailEventBus {
    private val mutable = MutableSharedFlow<MailEvent>(extraBufferCapacity = 16)
    val events: SharedFlow<MailEvent> = mutable.asSharedFlow()

    /**
     * Server calls still in flight behind an optimistically applied
     * mutation, from any screen. Pollers hold off while this is non-zero:
     * a STATUS taken before the server processes the write reads as "the
     * folder changed underneath us" and the reload would resurrect rows
     * the user already watched leave.
     */
    private val pendingWrites = AtomicInteger(0)

    val writesInFlight: Boolean get() = pendingWrites.get() > 0

    /** Pairs with [endWrite] (in a finally) around the server call. */
    fun beginWrite() {
        pendingWrites.incrementAndGet()
    }

    fun endWrite() {
        pendingWrites.decrementAndGet()
    }

    fun emit(event: MailEvent) {
        mutable.tryEmit(event)
    }
}

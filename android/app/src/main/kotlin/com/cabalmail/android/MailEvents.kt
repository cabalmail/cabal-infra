package com.cabalmail.android

import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.asSharedFlow
import java.util.concurrent.ConcurrentHashMap
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

    /**
     * Flag writes still in flight, keyed by (folder, uid) with a depth
     * count for overlapping writes to the same message. A band refetch
     * that lands mid-write must not clobber the optimistic patch with the
     * server's pre-write flags, so the list shields these rows until the
     * write settles.
     */
    private val pendingFlagWrites = ConcurrentHashMap<Pair<String, Long>, Int>()

    /** [beginWrite], plus shields [uids] from concurrent band refetches. */
    fun beginFlagWrite(
        folder: String,
        uids: Collection<Long>,
    ) {
        uids.forEach { pendingFlagWrites.merge(folder to it, 1, Int::plus) }
        beginWrite()
    }

    fun endFlagWrite(
        folder: String,
        uids: Collection<Long>,
    ) {
        uids.forEach { uid ->
            pendingFlagWrites.computeIfPresent(folder to uid) { _, depth ->
                (depth - 1).takeIf { it > 0 }
            }
        }
        endWrite()
    }

    fun flagWriteInFlight(
        folder: String,
        uid: Long,
    ): Boolean = pendingFlagWrites.containsKey(folder to uid)

    fun emit(event: MailEvent) {
        mutable.tryEmit(event)
    }
}

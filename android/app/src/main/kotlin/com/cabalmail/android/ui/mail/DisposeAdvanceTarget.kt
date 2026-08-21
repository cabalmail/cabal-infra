package com.cabalmail.android.ui.mail

import com.cabalmail.kit.models.Envelope
import com.cabalmail.kit.settings.DisposeAdvance

/**
 * Which envelope the reader opens after disposing [disposedUid], mirroring
 * the Apple clients' `advanceTarget(after:following:)`: each policy is a
 * directional scan over the displayed rows with one opposite-direction
 * fallback and no wraparound. [rows] is the loaded window in display order
 * (index 0 = newest); null means "no target — fall back to the list".
 * Callers must evaluate this *before* the disposal prunes the window.
 */
internal fun disposeAdvanceTarget(
    rows: List<Envelope>,
    disposedUid: Long,
    advance: DisposeAdvance,
): Envelope? {
    val index = rows.indexOfFirst { it.id == disposedUid }
    return when (advance) {
        DisposeAdvance.NEXT ->
            when {
                index < 0 -> rows.firstOrNull()
                index + 1 < rows.size -> rows[index + 1]
                index > 0 -> rows[index - 1]
                else -> null
            }
        DisposeAdvance.NEXT_UNREAD ->
            if (index < 0) {
                rows.firstOrNull { !it.isSeen }
            } else {
                rows.drop(index + 1).firstOrNull { !it.isSeen }
                    ?: rows.take(index).asReversed().firstOrNull { !it.isSeen }
            }
        DisposeAdvance.PREVIOUS_UNREAD ->
            if (index < 0) {
                rows.firstOrNull { !it.isSeen }
            } else {
                rows.take(index).asReversed().firstOrNull { !it.isSeen }
                    ?: rows.drop(index + 1).firstOrNull { !it.isSeen }
            }
        // The disposed message is skipped explicitly: its optimistic \Seen
        // flip may not have landed in the window yet.
        DisposeAdvance.FIRST_UNREAD -> rows.firstOrNull { it.id != disposedUid && !it.isSeen }
    }
}

package com.cabalmail.android.ui.flagged

import com.cabalmail.android.AppContainer
import com.cabalmail.android.MailEvent
import com.cabalmail.kit.models.Envelope
import com.cabalmail.kit.models.SearchFilters
import com.cabalmail.kit.models.SearchResult

/**
 * The mail half of the Flagged view, as the view model needs it: the
 * server's cross-folder search, and the writes a row can make. Every
 * write names the row's own folder, since the rows span folders. Narrow,
 * so the view model unit-tests against a scripted one.
 */
interface FlaggedMail {
    /** One page of `/search_envelopes` over every subscribed folder but Trash. */
    suspend fun search(
        filters: SearchFilters,
        cursor: String?,
        limit: Int,
    ): SearchResult

    /** Sets or clears [flag] on a message; [patched] is the envelope as the change leaves it. */
    suspend fun setFlag(
        folder: String,
        patched: Envelope,
        flag: String,
        value: Boolean,
    )

    suspend fun move(
        folder: String,
        uid: Long,
        destination: String,
        markSeen: Boolean,
    )

    /** Deletes for good; only ever asked for a message in Trash. */
    suspend fun purge(
        folder: String,
        uid: Long,
    )
}

/**
 * [FlaggedMail] over the app's API client, announcing each write on the
 * mail bus as the reader does: the change is posted before the server
 * confirms, so the folder's own list (often open underneath) follows at
 * once, and a failure asks that folder's viewers to read true state again
 * and is rethrown for the Flagged view to report.
 */
internal class ContainerFlaggedMail(
    private val container: AppContainer,
) : FlaggedMail {
    override suspend fun search(
        filters: SearchFilters,
        cursor: String?,
        limit: Int,
    ): SearchResult = container.requireApi().searchEnvelopes(filters = filters, limit = limit, cursor = cursor)

    override suspend fun setFlag(
        folder: String,
        patched: Envelope,
        flag: String,
        value: Boolean,
    ) {
        val uids = listOf(patched.id)
        container.mailEvents.emit(MailEvent.FlagChanged(folder, uids.toSet(), flag, value))
        container.mailEvents.beginFlagWrite(folder, uids)
        try {
            container.requireApi().setFlag(folder, uids, flag, value)
            container.envelopeCache.write(folder, listOf(patched))
        } catch (exception: Exception) {
            container.mailEvents.emit(MailEvent.Reconcile(folder))
            throw exception
        } finally {
            container.mailEvents.endFlagWrite(folder, uids)
        }
    }

    override suspend fun move(
        folder: String,
        uid: Long,
        destination: String,
        markSeen: Boolean,
    ) = departing(folder, uid, destination) {
        container.requireApi().moveMessages(folder, destination, listOf(uid), markSeen = markSeen)
    }

    override suspend fun purge(
        folder: String,
        uid: Long,
    ) = departing(folder, uid, destination = null) {
        container.requireApi().purgeMessages(folder, listOf(uid))
    }

    /** The write is opened before the event, so a screen that answers it by reading server state can wait. */
    private suspend fun departing(
        folder: String,
        uid: Long,
        destination: String?,
        action: suspend () -> Unit,
    ) {
        container.mailEvents.beginWrite()
        container.mailEvents.emit(MailEvent.Removed(folder, setOf(uid), destination))
        try {
            action()
            container.envelopeCache.invalidateFolder(folder)
            container.bodyCache.remove(folder, uid)
        } catch (exception: Exception) {
            container.mailEvents.emit(MailEvent.Reconcile(folder))
            throw exception
        } finally {
            container.mailEvents.endWrite()
        }
    }
}

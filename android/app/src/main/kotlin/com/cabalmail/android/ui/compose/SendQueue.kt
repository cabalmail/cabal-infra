package com.cabalmail.android.ui.compose

import com.cabalmail.android.AppContainer
import com.cabalmail.android.isTransient
import com.cabalmail.kit.compose.ComposePayload
import com.cabalmail.kit.models.ComposeIntent
import com.cabalmail.kit.models.Draft
import com.cabalmail.kit.models.DraftAttachment
import com.cabalmail.kit.models.OutgoingAttachment
import com.cabalmail.kit.models.SendOutcome
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.drop
import kotlinx.coroutines.flow.filter
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.io.File

/**
 * The outbox (plan §7.4): a send that fails for a transient reason (or is
 * attempted offline) parks the draft in the local buffer with the
 * Message-ID it will be sent under, and [flush] retries every queued draft
 * when connectivity returns and at launch. The stable Message-ID means a
 * retry the server already delivered is deduplicated, never re-sent.
 *
 * Outcomes surface as one-line [notices] the shell shows in a snackbar.
 */
class SendQueue(
    private val container: AppContainer,
) {
    private val mutableNotices = MutableSharedFlow<String>(extraBufferCapacity = 4)
    val notices: SharedFlow<String> = mutableNotices.asSharedFlow()
    private val flushing = Mutex()

    /** Wires the reconnect trigger; call once from the container. */
    fun start() {
        container.appScope.launch {
            container.connectivity.online
                .drop(1)
                .filter { it }
                .collect { flush() }
        }
    }

    /** Parks [draft] for a later send under [messageId]. */
    suspend fun enqueue(
        draft: Draft,
        messageId: String,
    ) {
        container.draftStore.save(draft.copy(queuedMessageId = messageId))
        mutableNotices.tryEmit("Queued — will send when back online")
    }

    /** Sends every queued draft it can; leaves the rest for the next trigger. */
    suspend fun flush() {
        if (!container.connectivity.online.value) {
            return
        }
        flushing.withLock {
            val queued = container.draftStore.list().filter { it.queuedMessageId != null }
            if (queued.isEmpty()) {
                return
            }
            var sent = 0
            for (draft in queued) {
                val messageId = draft.queuedMessageId ?: continue
                val from = draft.fromAddress ?: continue
                try {
                    val api = container.requireApi()
                    val staged = stage(draft.attachments)
                    val fields = ComposePayload.build(draft, from, messageId = messageId, staged = staged)
                    when (api.send(fields, draft.serverUid, draft.serverUidValidity)) {
                        is SendOutcome.Submitted -> {
                            sent += 1
                            markAnswered(draft)
                            container.recipientHistory.record(draft.to + draft.cc + draft.bcc)
                            container.draftStore.delete(draft.id)
                        }
                        SendOutcome.DuplicateInFlight -> Unit // still claimed server-side; retry later
                    }
                } catch (exception: Exception) {
                    if (!isTransient(exception)) {
                        // A definitive rejection: stop retrying, keep the
                        // draft as an ordinary unsent one so it is offered.
                        container.draftStore.save(draft.copy(queuedMessageId = null))
                        mutableNotices.tryEmit(
                            "Couldn't send \"${draft.subject.ifBlank { "(no subject)" }}\" — kept as a draft",
                        )
                    }
                }
            }
            if (sent > 0) {
                mutableNotices.tryEmit(if (sent == 1) "Queued message sent" else "$sent queued messages sent")
            }
        }
    }

    private suspend fun stage(attachments: List<DraftAttachment>): List<OutgoingAttachment> {
        if (attachments.isEmpty()) {
            return emptyList()
        }
        val api = container.requireApi()
        val grants = api.requestUploadUrls(attachments.map { it.filename to it.mimeType })
        return attachments.zip(grants).map { (attachment, grant) ->
            api.uploadToGrant(grant.url, attachment.mimeType, File(attachment.path).readBytes())
            OutgoingAttachment(filename = attachment.filename, mimeType = attachment.mimeType, s3Key = grant.key)
        }
    }

    private suspend fun markAnswered(draft: Draft) {
        val folder = draft.replySourceFolder ?: return
        val uid = draft.replySourceUid ?: return
        if (draft.composeIntent != ComposeIntent.REPLY && draft.composeIntent != ComposeIntent.REPLY_ALL) {
            return
        }
        runCatching { container.requireApi().setFlag(folder, listOf(uid), "\\Answered", true) }
    }
}

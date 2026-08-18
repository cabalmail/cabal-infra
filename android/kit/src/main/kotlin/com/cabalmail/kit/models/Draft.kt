package com.cabalmail.kit.models

import kotlinx.serialization.Serializable

/**
 * Why a compose session was opened. Carried on the seed [Draft] so the
 * compose screen can route initial focus and reply-style scaffolding
 * without inferring it from threading headers — a resumed draft can carry
 * `In-Reply-To` without being a freshly seeded reply.
 */
@Serializable
enum class ComposeIntent { NEW, REPLY, REPLY_ALL, FORWARD }

/**
 * Server-side coordinates of a draft copy in the IMAP `Drafts` folder, as
 * reported by `/save_draft` (UIDPLUS `APPENDUID`). Only meaningful as a
 * pair — a UID can be reused after a UIDVALIDITY bump — so every replace /
 * discard sends both and the Lambda's guard declines on mismatch.
 */
@Serializable
data class DraftServerRef(
    val uid: Long,
    val uidValidity: Long,
)

/**
 * A file the user attached while composing, copied into the draft's own
 * directory (see `DraftStore.attachmentFile`) so it survives process death
 * and needs no persistable URI grant. Staged to S3 at send / server-save
 * time via `/upload_url`.
 */
@Serializable
data class DraftAttachment(
    val filename: String,
    val mimeType: String,
    /** Absolute path of the local copy. */
    val path: String,
    val size: Long,
)

/**
 * Locally persisted compose state — the live editing buffer and the
 * crash-recovery story (plan §5.3). The body is **Markdown source**: both
 * first-party composers are Markdown-canonical and emit the source as the
 * message's `text/plain` part, which is what makes a draft saved here
 * round-trip losslessly through the Apple and web clients.
 *
 * Cross-device sync layers on top: compose pushes this buffer to the IMAP
 * `Drafts` folder via `/save_draft`, recording [serverUid] /
 * [serverUidValidity] so the next save replaces the prior copy and a send
 * discards it. Recipients are bare `mailbox@host` strings.
 */
@Serializable
data class Draft(
    val id: String,
    /** Epoch millis of the last local edit. */
    val updatedAt: Long,
    val fromAddress: String? = null,
    val to: List<String> = emptyList(),
    val cc: List<String> = emptyList(),
    val bcc: List<String> = emptyList(),
    val subject: String = "",
    /** Markdown source. */
    val body: String = "",
    /** Bare (angle-bracket-free) message id this draft replies to. */
    val inReplyTo: String? = null,
    /** Bare message ids, oldest first. */
    val references: List<String> = emptyList(),
    val composeIntent: ComposeIntent = ComposeIntent.NEW,
    val serverUid: Long? = null,
    val serverUidValidity: Long? = null,
    /**
     * Coordinates of the message this draft replies to, so a successful
     * send can mark it `\Answered`. Set by reply / reply-all seeds only —
     * never forwards. Best-effort by design.
     */
    val replySourceFolder: String? = null,
    val replySourceUid: Long? = null,
    val attachments: List<DraftAttachment> = emptyList(),
    /**
     * The body as seeded (signature scaffold, reply quote, forward banner)
     * so an untouched seed still counts as [isEmpty]. Empty for resumed
     * server drafts, whose body is user content by definition.
     */
    val seedBody: String = "",
    /**
     * Set when a send failed for a transient reason and the draft waits in
     * the outbox: the Message-ID it will be sent with, kept stable so the
     * server's dedupe claim recognizes the retry.
     */
    val queuedMessageId: String? = null,
) {
    /** The server coordinates when both halves are present. */
    val serverRef: DraftServerRef?
        get() {
            val uid = serverUid ?: return null
            val validity = serverUidValidity ?: return null
            return DraftServerRef(uid, validity)
        }

    fun withServerRef(ref: DraftServerRef?): Draft = copy(serverUid = ref?.uid, serverUidValidity = ref?.uidValidity)

    /**
     * Nothing worth keeping: no recipients, subject, or attachments, and a
     * body the user has not touched since it was seeded. A selected From
     * alone does not make a draft (the picker is the first thing every
     * compose touches), and neither does an untouched signature or quote.
     */
    val isEmpty: Boolean
        get() =
            to.isEmpty() &&
                cc.isEmpty() &&
                bcc.isEmpty() &&
                subject.isBlank() &&
                attachments.isEmpty() &&
                (body.isBlank() || body.trim() == seedBody.trim())
}

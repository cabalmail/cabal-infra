package com.cabalmail.kit.compose

import com.cabalmail.kit.models.ComposeFields
import com.cabalmail.kit.models.Draft
import com.cabalmail.kit.models.OtherHeaders
import com.cabalmail.kit.models.OutgoingAttachment

/**
 * Assembles the `/send` / `/save_draft` compose payload from a [Draft].
 * The single seam every sender passes through: Markdown source as `text`,
 * its rendering as `html`, and message ids normalized to their
 * angle-bracketed wire form.
 *
 * [messageId] is stamped only when sending — a draft saved without one
 * stays outside `/send`'s dedupe window until send assigns it (see
 * `docs/draft-sync-and-threading.md`).
 */
object ComposePayload {
    fun build(
        draft: Draft,
        sender: String,
        messageId: String? = null,
        staged: List<OutgoingAttachment> = emptyList(),
    ): ComposeFields =
        ComposeFields(
            sender = sender,
            toList = draft.to,
            ccList = draft.cc,
            bccList = draft.bcc,
            subject = draft.subject,
            text = draft.body,
            html = Markdown.toHtml(draft.body),
            otherHeaders =
                OtherHeaders(
                    messageId = MessageIds.angleWrapped(messageId)?.let(::listOf) ?: emptyList(),
                    inReplyTo = MessageIds.angleWrapped(draft.inReplyTo)?.let(::listOf) ?: emptyList(),
                    references = draft.references.mapNotNull(MessageIds::angleWrapped),
                ),
            attachments = staged,
        )
}

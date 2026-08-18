package com.cabalmail.kit.compose

import com.cabalmail.kit.mime.RawHeaders
import com.cabalmail.kit.mime.RawHeaders.valueOf
import com.cabalmail.kit.models.ComposeIntent
import com.cabalmail.kit.models.Draft
import com.cabalmail.kit.models.DraftServerRef
import com.cabalmail.kit.models.Envelope
import com.cabalmail.kit.models.MessageContent
import com.cabalmail.kit.models.mailboxAddress
import java.util.UUID

/**
 * Builds the compose seed for **Edit Draft** on a message in the `Drafts`
 * folder (plan §5.3): recipients and subject from the envelope, Bcc from
 * the raw headers (the only place it lives), threading from the fetched
 * body's headers, and the body from the `text/plain` part — lossless for
 * first-party drafts because compose is Markdown-canonical. An HTML-only
 * foreign draft falls back to editing its HTML through the Markdown buffer
 * (Markdown passes inline HTML through, so nothing is lost).
 *
 * The seed points [Draft.serverUid] / [Draft.serverUidValidity] at the copy
 * being resumed, so the first re-save replaces it and a send discards it.
 */
object DraftResume {
    fun seed(
        envelope: Envelope,
        content: MessageContent,
        rawHeaders: List<RawHeaders.Header>,
        serverRef: DraftServerRef?,
        now: Long = System.currentTimeMillis(),
        id: String = UUID.randomUUID().toString(),
    ): Draft {
        val identity = ThreadingIdentity.resolve(envelope, content)
        return Draft(
            id = id,
            updatedAt = now,
            fromAddress = envelope.from.firstOrNull()?.let { mailboxAddress(it) },
            to = envelope.to.mapNotNull { mailboxAddress(it) },
            cc = envelope.cc.mapNotNull { mailboxAddress(it) },
            bcc = RawHeaders.addressList(rawHeaders.valueOf("Bcc")),
            subject = envelope.subject,
            body = body(content.bodyPlain, content.bodyHtml),
            inReplyTo = identity.inReplyTo,
            references = identity.references,
            // Resumed drafts open as ordinary composes: the body is the
            // user's own words, not a quoted original.
            composeIntent = ComposeIntent.NEW,
            serverUid = serverRef?.uid,
            serverUidValidity = serverRef?.uidValidity,
        )
    }

    /** Prefer the Markdown-source plain part; fall back to raw HTML. */
    fun body(
        plainText: String?,
        htmlBody: String?,
    ): String = plainText?.takeIf { it.isNotBlank() } ?: htmlBody.orEmpty()
}

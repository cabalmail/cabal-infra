package com.cabalmail.kit.compose

import com.cabalmail.kit.models.ComposeIntent
import com.cabalmail.kit.models.Draft
import com.cabalmail.kit.models.Envelope
import com.cabalmail.kit.models.MessageContent
import com.cabalmail.kit.models.mailboxAddress
import com.cabalmail.kit.models.mailboxDisplayName
import com.cabalmail.kit.models.sentInstant
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale
import java.util.UUID

/**
 * Seeds a [Draft] from an original message for reply / reply-all / forward
 * (plan §5.2), the Kotlin sibling of the Apple `ReplyBuilder`.
 *
 * ### On-the-fly From
 * Every outgoing Cabalmail message is expected to originate from an address
 * the user minted *for this correspondent*, so replies default From to the
 * owned address the original was sent to (To → Cc), and fall back to no
 * selection — the compose screen then leads with "Create new address…".
 *
 * ### Reply from Sent
 * Replying to the user's own message (read out of the Sent folder, From
 * owned by the user) inverts the addressing instead: From reuses the alias
 * the original was sent from, Reply goes to the original To, and Reply All
 * carries the original To / Cc / Bcc. The author never appears in the
 * recipient lists.
 *
 * ### Threading
 * An open message overlays the ids parsed from the fetched body
 * ([MessageContent]) onto the envelope, so replies thread correctly even
 * off a cached envelope that predates the threading rollout. Forward
 * deliberately breaks the thread.
 */
object ReplyBuilder {
    enum class Mode { REPLY, REPLY_ALL, FORWARD }

    private const val SENT_FOLDER = "Sent"

    fun build(
        envelope: Envelope,
        content: MessageContent?,
        mode: Mode,
        ownedAddresses: Collection<String>,
        sourceFolder: String?,
        now: Instant = Instant.now(),
        zone: ZoneId = ZoneId.systemDefault(),
        id: String = UUID.randomUUID().toString(),
    ): Draft {
        val owned = ownedAddresses.map { it.lowercase() }.toSet()

        // A message read out of Sent whose From is one of the user's own
        // addresses is their own outbound copy, and replying to it inverts
        // the addressing (see the class doc). The ownership check keeps the
        // inversion off messages merely filed into Sent by hand.
        val ownFrom = bareAddresses(envelope.from).firstOrNull()?.lowercase()
        val isOwnMessage = sourceFolder == SENT_FOLDER && ownFrom in owned

        val fromAddress = if (isOwnMessage) ownFrom else pickDefaultFrom(envelope, owned)
        val subject = prefixedSubject(envelope.subject, mode)

        val (to, cc, bcc) =
            when {
                isOwnMessage && mode == Mode.REPLY -> {
                    val seen = owned.toMutableSet()
                    Triple(deduped(envelope.to, seen), emptyList<String>(), emptyList<String>())
                }
                isOwnMessage && mode == Mode.REPLY_ALL -> {
                    // One shared seen-set so an address never lands in more
                    // than one of To / Cc / Bcc.
                    val seen = owned.toMutableSet()
                    Triple(deduped(envelope.to, seen), deduped(envelope.cc, seen), deduped(envelope.bcc, seen))
                }
                mode == Mode.REPLY ->
                    Triple(bareAddresses(envelope.from), emptyList<String>(), emptyList<String>())
                mode == Mode.REPLY_ALL -> {
                    val recipients = deduped(envelope.from + envelope.to + envelope.cc, owned.toMutableSet())
                    Triple(recipients.take(1), recipients.drop(1), emptyList<String>())
                }
                else -> Triple(emptyList<String>(), emptyList<String>(), emptyList<String>())
            }

        val originalBody = quotableBody(content)
        val body =
            when (mode) {
                Mode.FORWARD -> forwardQuote(originalBody, envelope, zone)
                else -> replyQuote(originalBody, envelope, zone)
            }

        val threading = threadingHeaders(envelope, content, mode)
        val isReply = mode != Mode.FORWARD
        return Draft(
            id = id,
            updatedAt = now.toEpochMilli(),
            fromAddress = fromAddress,
            to = to,
            cc = cc,
            bcc = bcc,
            subject = subject,
            body = body,
            inReplyTo = threading.first,
            references = threading.second,
            composeIntent =
                when (mode) {
                    Mode.REPLY -> ComposeIntent.REPLY
                    Mode.REPLY_ALL -> ComposeIntent.REPLY_ALL
                    Mode.FORWARD -> ComposeIntent.FORWARD
                },
            replySourceFolder = if (isReply) sourceFolder else null,
            replySourceUid = if (isReply && sourceFolder != null) envelope.id else null,
        )
    }

    // ------------------------------------------------------------- subject

    /** `Re: ` / `Fwd: ` prefix, idempotent — no `Re: Re:`. */
    fun prefixedSubject(
        raw: String,
        mode: Mode,
    ): String {
        val trimmed = raw.trim()
        val prefix = if (mode == Mode.FORWARD) "Fwd: " else "Re: "
        return if (trimmed.lowercase().startsWith(prefix.lowercase())) trimmed else prefix + trimmed
    }

    // ---------------------------------------------------------------- from

    private fun pickDefaultFrom(
        envelope: Envelope,
        owned: Set<String>,
    ): String? = bareAddresses(envelope.to + envelope.cc).firstOrNull { it.lowercase() in owned }?.lowercase()

    private fun bareAddresses(mailboxes: List<String>): List<String> = mailboxes.mapNotNull { mailboxAddress(it) }

    /**
     * Bare addresses, first occurrence wins, minus anything already in
     * [seen]. Seed [seen] with the owned set to keep the user out of the
     * recipients; pass the same set across calls to keep an address from
     * landing in more than one of To / Cc / Bcc.
     */
    private fun deduped(
        mailboxes: List<String>,
        seen: MutableSet<String>,
    ): List<String> = bareAddresses(mailboxes).filter { seen.add(it.lowercase()) }

    // ------------------------------------------------------------- quoting

    /** Plain part if present, else a text rendition of the HTML part. */
    private fun quotableBody(content: MessageContent?): String? {
        content ?: return null
        if (content.bodyPlain.isNotBlank()) {
            return content.bodyPlain.trim()
        }
        if (content.bodyHtml.isNotBlank()) {
            return HtmlText.toPlainText(content.bodyHtml).takeIf { it.isNotBlank() }
        }
        return null
    }

    /**
     * Separator + attribution + the original as ordinary paragraphs, led by
     * two blank lines so the cursor lands above the rule. Markdown-canonical:
     * `---` renders as a horizontal rule in every first-party client.
     */
    private fun replyQuote(
        body: String?,
        envelope: Envelope,
        zone: ZoneId,
    ): String {
        if (body.isNullOrEmpty()) {
            return ""
        }
        return "\n\n---\n${attributionLine(envelope, zone)}\n\n$body"
    }

    private fun forwardQuote(
        body: String?,
        envelope: Envelope,
        zone: ZoneId,
    ): String {
        val header = StringBuilder("---------- Forwarded message ----------\n")
        envelope.from.firstOrNull()?.let { header.append("From: ").append(it).append('\n') }
        header.append("Subject: ").append(envelope.subject).append('\n')
        envelope.sentInstant()?.let {
            header
                .append(
                    "Date: ",
                ).append(RFC_5322_DATE.withZone(zone).format(it))
                .append('\n')
        }
        if (envelope.to.isNotEmpty()) {
            header.append("To: ").append(envelope.to.joinToString(", ")).append('\n')
        }
        header.append('\n').append(body.orEmpty())
        return "\n\n$header"
    }

    private fun attributionLine(
        envelope: Envelope,
        zone: ZoneId,
    ): String {
        val sender = envelope.from.firstOrNull()?.let { mailboxDisplayName(it) } ?: "someone"
        val sent = envelope.sentInstant() ?: return "$sender wrote:"
        return "On ${ATTRIBUTION_DATE.withZone(zone).format(sent)}, $sender wrote:"
    }

    private val ATTRIBUTION_DATE = DateTimeFormatter.ofPattern("EEE, MMM d, yyyy 'at' h:mm a", Locale.US)
    private val RFC_5322_DATE = DateTimeFormatter.ofPattern("EEE, d MMM yyyy HH:mm:ss Z", Locale.US)

    // ----------------------------------------------------------- threading

    /**
     * `In-Reply-To` = the original's Message-ID; `References` = the
     * original's chain plus its Message-ID, degrading to
     * `[In-Reply-To, Message-ID]` when no chain is known. Fetched-body
     * headers win over the (possibly stale) envelope. Forwards carry none.
     */
    private fun threadingHeaders(
        envelope: Envelope,
        content: MessageContent?,
        mode: Mode,
    ): Pair<String?, List<String>> {
        if (mode == Mode.FORWARD) {
            return null to emptyList()
        }
        val identity = ThreadingIdentity.resolve(envelope, content)
        val messageId = identity.messageId
        val references =
            identity.references.ifEmpty { listOfNotNull(identity.inReplyTo) }.toMutableList()
        if (messageId != null && messageId !in references) {
            references.add(messageId)
        }
        return messageId to references
    }
}

/** Bare message-id triple for a message, from the freshest source available. */
data class ThreadingIdentity(
    val messageId: String?,
    val inReplyTo: String?,
    val references: List<String>,
) {
    companion object {
        /**
         * Overlays the fetched body's raw headers (when present and
         * non-empty) on the envelope's pre-split lists.
         */
        fun resolve(
            envelope: Envelope,
            content: MessageContent?,
        ): ThreadingIdentity {
            val contentMessageId = MessageIds.parseAll(content?.messageId).firstOrNull()
            val contentInReplyTo = MessageIds.parseAll(content?.inReplyTo).firstOrNull()
            val contentReferences = MessageIds.parseAll(content?.references)
            return ThreadingIdentity(
                messageId = contentMessageId ?: envelope.messageId.firstOrNull()?.let(MessageIds::bare),
                inReplyTo = contentInReplyTo ?: envelope.inReplyTo.firstOrNull()?.let(MessageIds::bare),
                references = contentReferences.ifEmpty { envelope.references.map(MessageIds::bare) },
            )
        }
    }
}

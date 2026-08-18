package com.cabalmail.kit.compose

import com.cabalmail.kit.models.ComposeIntent
import com.cabalmail.kit.models.Envelope
import com.cabalmail.kit.models.MessageContent
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import java.time.Instant
import java.time.ZoneOffset

class ReplyBuilderTest {
    private val owned = listOf("me@shop.example.com", "me@work.example.com")

    private val envelope =
        Envelope(
            id = 42,
            date = "2026-08-01 10:15:00+00:00",
            subject = "Order update",
            from = listOf("\"Ann Vendor\" <ann@vendor.example>"),
            to = listOf("Me <me@shop.example.com>", "Bob <bob@vendor.example>"),
            cc = listOf("me@work.example.com"),
            messageId = listOf("<orig@vendor.example>"),
            inReplyTo = listOf("<earlier@vendor.example>"),
            references = listOf("<root@vendor.example>", "<earlier@vendor.example>"),
        )

    private val content =
        MessageContent(bodyPlain = "Your order shipped.\nThanks!")

    private fun build(
        mode: ReplyBuilder.Mode,
        withContent: MessageContent? = content,
    ) = ReplyBuilder.build(
        envelope = envelope,
        content = withContent,
        mode = mode,
        ownedAddresses = owned,
        sourceFolder = "INBOX",
        now = Instant.parse("2026-08-02T00:00:00Z"),
        zone = ZoneOffset.UTC,
        id = "draft-1",
    )

    @Test
    fun `reply targets the author and defaults From to the addressed owned address`() {
        val draft = build(ReplyBuilder.Mode.REPLY)
        assertEquals(listOf("ann@vendor.example"), draft.to)
        assertTrue(draft.cc.isEmpty())
        assertEquals("me@shop.example.com", draft.fromAddress)
        assertEquals("Re: Order update", draft.subject)
        assertEquals(ComposeIntent.REPLY, draft.composeIntent)
        assertEquals("INBOX", draft.replySourceFolder)
        assertEquals(42L, draft.replySourceUid)
    }

    @Test
    fun `reply-all dedupes and drops owned addresses`() {
        val draft = build(ReplyBuilder.Mode.REPLY_ALL)
        assertEquals(listOf("ann@vendor.example"), draft.to)
        assertEquals(listOf("bob@vendor.example"), draft.cc)
    }

    @Test
    fun `threading chains references and appends the original id`() {
        val draft = build(ReplyBuilder.Mode.REPLY)
        assertEquals("orig@vendor.example", draft.inReplyTo)
        assertEquals(
            listOf("root@vendor.example", "earlier@vendor.example", "orig@vendor.example"),
            draft.references,
        )
    }

    @Test
    fun `threading degrades to in-reply-to plus id without a chain`() {
        val bare = envelope.copy(references = emptyList())
        val draft =
            ReplyBuilder.build(bare, null, ReplyBuilder.Mode.REPLY, owned, "INBOX", id = "d")
        assertEquals(listOf("earlier@vendor.example", "orig@vendor.example"), draft.references)
    }

    @Test
    fun `fetched-body headers overlay a stale envelope`() {
        val stale = envelope.copy(messageId = emptyList(), references = emptyList(), inReplyTo = emptyList())
        val fetched =
            content.copy(
                messageId = listOf("<fresh@vendor.example>"),
                references = listOf("<a@x> <b@y>"),
            )
        val draft = ReplyBuilder.build(stale, fetched, ReplyBuilder.Mode.REPLY, owned, "INBOX", id = "d")
        assertEquals("fresh@vendor.example", draft.inReplyTo)
        assertEquals(listOf("a@x", "b@y", "fresh@vendor.example"), draft.references)
    }

    @Test
    fun `forward breaks the thread and quotes with a banner`() {
        val draft = build(ReplyBuilder.Mode.FORWARD)
        assertNull(draft.inReplyTo)
        assertTrue(draft.references.isEmpty())
        assertTrue(draft.to.isEmpty())
        assertEquals("Fwd: Order update", draft.subject)
        assertNull(draft.replySourceFolder)
        assertTrue(draft.body.contains("---------- Forwarded message ----------"))
        assertTrue(draft.body.contains("Your order shipped."))
        assertEquals(ComposeIntent.FORWARD, draft.composeIntent)
    }

    @Test
    fun `reply quote carries an attribution line above the original`() {
        val draft = build(ReplyBuilder.Mode.REPLY)
        assertEquals(
            "\n\n---\nOn Sat, Aug 1, 2026 at 10:15 AM, Ann Vendor wrote:\n\nYour order shipped.\nThanks!",
            draft.body,
        )
    }

    @Test
    fun `html-only originals quote a text rendition`() {
        val html = MessageContent(bodyHtml = "<p>Hello <b>there</b></p><p>Bye &amp; thanks</p>")
        val draft = build(ReplyBuilder.Mode.REPLY, withContent = html)
        assertTrue(draft.body.contains("Hello there\nBye & thanks"))
    }

    @Test
    fun `no owned recipient leaves From unset`() {
        val foreign = envelope.copy(to = listOf("other@x.example"), cc = emptyList())
        val draft = ReplyBuilder.build(foreign, null, ReplyBuilder.Mode.REPLY, owned, null, id = "d")
        assertNull(draft.fromAddress)
        assertNull(draft.replySourceUid)
    }

    @Test
    fun `subject prefixing is idempotent and case-insensitive`() {
        assertEquals("re: x", ReplyBuilder.prefixedSubject("re: x", ReplyBuilder.Mode.REPLY))
        assertEquals("Fwd: x", ReplyBuilder.prefixedSubject("Fwd: x", ReplyBuilder.Mode.FORWARD))
        assertEquals("Fwd: Re: x", ReplyBuilder.prefixedSubject("Re: x", ReplyBuilder.Mode.FORWARD))
    }
}

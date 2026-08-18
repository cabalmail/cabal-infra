package com.cabalmail.kit.compose

import com.cabalmail.kit.mime.RawHeaders
import com.cabalmail.kit.mime.RawHeaders.valueOf
import com.cabalmail.kit.models.ComposeIntent
import com.cabalmail.kit.models.Draft
import com.cabalmail.kit.models.DraftServerRef
import com.cabalmail.kit.models.Envelope
import com.cabalmail.kit.models.MessageContent
import com.cabalmail.kit.models.OutgoingAttachment
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import kotlin.random.Random

class ComposeHelpersTest {
    @Test
    fun `message ids parse folded and comma-separated values`() {
        assertEquals(listOf("a@x", "b@y"), MessageIds.parse("<a@x>\n <b@y>"))
        assertEquals(listOf("a@x", "b@y"), MessageIds.parse("<a@x>, <b@y>"))
        assertEquals(listOf("bare@x"), MessageIds.parse("bare@x"))
        assertTrue(MessageIds.parse("  ").isEmpty())
        assertEquals("<a@x>", MessageIds.angleWrapped("a@x"))
        assertEquals("<a@x>", MessageIds.angleWrapped(" <a@x> "))
        assertNull(MessageIds.angleWrapped(""))
        assertTrue(MessageIds.generate("host.example").matches(Regex("<[0-9a-f-]{36}@host\\.example>")))
    }

    @Test
    fun `payload wraps ids and stamps message id only when given`() {
        val draft =
            Draft(
                id = "d",
                updatedAt = 0,
                to = listOf("a@x"),
                subject = "Hi",
                body = "Hello **world**",
                inReplyTo = "orig@x",
                references = listOf("root@x", "orig@x"),
            )
        val send = ComposePayload.build(draft, "me@sub.example.com", messageId = "<new@sub.example.com>")
        assertEquals(listOf("<new@sub.example.com>"), send.otherHeaders.messageId)
        assertEquals(listOf("<orig@x>"), send.otherHeaders.inReplyTo)
        assertEquals(listOf("<root@x>", "<orig@x>"), send.otherHeaders.references)
        assertEquals("Hello **world**", send.text)
        assertTrue(send.html.contains("<strong>world</strong>"))

        val save =
            ComposePayload.build(
                draft,
                "me@sub.example.com",
                staged = listOf(OutgoingAttachment("f", "text/plain", "k")),
            )
        assertTrue(save.otherHeaders.messageId.orEmpty().isEmpty())
        assertEquals("k", save.attachments.single().s3Key)
    }

    @Test
    fun `markdown renders a fragment and passes inline html through`() {
        assertEquals("", Markdown.toHtml("   "))
        val html = Markdown.toHtml("# Title\n\nA [link](https://x.example) and <em>raw</em>.")
        assertTrue(html.startsWith("<h1>"), html)
        assertFalse(html.contains("<body>"))
        assertTrue(html.contains("href=\"https://x.example\""))
        assertTrue(html.contains("<em>raw</em>"))
    }

    @Test
    fun `raw headers unfold and split address lists`() {
        val raw =
            "From: me@x\r\nBcc: \"Doe, Jane\" <jane@y>,\r\n bob@z\r\nSubject: s\r\n\r\nBody: not a header\r\n"
        val headers = RawHeaders.parse(raw)
        assertEquals("\"Doe, Jane\" <jane@y>, bob@z", headers.valueOf("bcc"))
        assertNull(headers.valueOf("Body"))
        assertEquals(listOf("jane@y", "bob@z"), RawHeaders.addressList(headers.valueOf("Bcc")))
    }

    @Test
    fun `draft resume prefers plain part and reads bcc from headers`() {
        val envelope =
            Envelope(
                id = 7,
                subject = "Draft subj",
                from = listOf("me@sub.example.com"),
                to = listOf("A <a@x>"),
                cc = listOf("c@x"),
            )
        val content =
            MessageContent(
                bodyPlain = "*markdown* body",
                bodyHtml = "<p><em>markdown</em> body</p>",
                inReplyTo = listOf("<orig@x>"),
                references = listOf("<root@x> <orig@x>"),
            )
        val headers = RawHeaders.parse("Bcc: hidden@x\r\n\r\n")
        val draft = DraftResume.seed(envelope, content, headers, DraftServerRef(7, 99), now = 1, id = "r")
        assertEquals("me@sub.example.com", draft.fromAddress)
        assertEquals(listOf("a@x"), draft.to)
        assertEquals(listOf("c@x"), draft.cc)
        assertEquals(listOf("hidden@x"), draft.bcc)
        assertEquals("*markdown* body", draft.body)
        assertEquals("orig@x", draft.inReplyTo)
        assertEquals(listOf("root@x", "orig@x"), draft.references)
        assertEquals(ComposeIntent.NEW, draft.composeIntent)
        assertEquals(DraftServerRef(7, 99), draft.serverRef)
        assertEquals("<p>x</p>", DraftResume.body("  ", "<p>x</p>"))
    }

    @Test
    fun `draft emptiness ignores From alone`() {
        assertTrue(Draft(id = "d", updatedAt = 0, fromAddress = "me@x").isEmpty)
        val seeded = "\n\n-- \nsig"
        assertTrue(Draft(id = "d", updatedAt = 0, body = seeded, seedBody = seeded).isEmpty)
        assertFalse(Draft(id = "d", updatedAt = 0, body = "hi$seeded", seedBody = seeded).isEmpty)
        assertFalse(Draft(id = "d", updatedAt = 0, body = "kept").isEmpty)
        assertFalse(Draft(id = "d", updatedAt = 0, subject = "x").isEmpty)
        assertFalse(Draft(id = "d", updatedAt = 0, to = listOf("a@x")).isEmpty)
    }

    @Test
    fun `address mint labels are valid dns labels`() {
        val label = AddressMint.randomLabel(random = Random(1))
        assertEquals(8, label.length)
        assertTrue(label.all { it in AddressMint.LABEL_ALPHABET })
        assertEquals("my-shop-2", AddressMint.normalizeLabel("  My Shop_2! "))
        assertNull(AddressMint.normalizeLabel("!!!"))
    }

    @Test
    fun `html text strips tags and decodes entities`() {
        assertEquals(
            "One\nTwo & three\n\nfour",
            HtmlText.toPlainText("<style>p{}</style><div>One</div><p>Two &amp; three</p><br><br>four"),
        )
    }
}

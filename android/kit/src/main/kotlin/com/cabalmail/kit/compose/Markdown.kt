package com.cabalmail.kit.compose

import org.intellij.markdown.flavours.gfm.GFMFlavourDescriptor
import org.intellij.markdown.html.HtmlGenerator
import org.intellij.markdown.parser.MarkdownParser

/**
 * Markdown → HTML for the outgoing `text/html` part. The compose buffer is
 * Markdown-canonical (plan §5.1): the Markdown source ships as the
 * `text/plain` part and this rendering as the HTML alternative, the same
 * split the Apple composer produces via marked.
 *
 * GFM flavour so autolinks, strikethrough, and tables render; inline HTML
 * passes through, which is what makes an HTML-only foreign draft editable
 * through the Markdown buffer without loss.
 */
object Markdown {
    private val flavour = GFMFlavourDescriptor()

    /** Renders [source] to an HTML fragment (no `<html>`/`<body>` wrapper). */
    fun toHtml(source: String): String {
        if (source.isBlank()) {
            return ""
        }
        val tree = MarkdownParser(flavour).buildMarkdownTreeFromString(source)
        val html = HtmlGenerator(source, tree, flavour).generateHtml()
        return html.removePrefix("<body>").removeSuffix("</body>").trim()
    }
}

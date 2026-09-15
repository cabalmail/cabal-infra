package com.cabalmail.kit.compose

/**
 * Best-effort HTML → plain text: [toPlainText] for quoting an HTML-only
 * original in a reply, [firstLine] for a list row's preview line. Not a
 * renderer: drops scripts/styles, turns block boundaries into line breaks,
 * strips every other tag, and decodes the common entities. Good enough for
 * an attribution block; the recipient's own client still renders whatever
 * the user types above it.
 */
object HtmlText {
    private val DROP = Regex("""(?is)<(script|style|head)\b.*?</\1\s*>""")
    private val BREAK = Regex("""(?i)<br\s*/?>""")
    private val BLOCK_END = Regex("""(?i)</(p|div|li|h[1-6]|tr|blockquote|pre|table|ul|ol)\s*>""")
    private val TAG = Regex("""<[^>]+>""")
    private val ENTITY = Regex("""&(#x[0-9a-fA-F]+|#[0-9]+|[a-zA-Z]+);""")
    private val NAMED =
        mapOf(
            "amp" to "&",
            "lt" to "<",
            "gt" to ">",
            "quot" to "\"",
            "apos" to "'",
            "nbsp" to " ",
            "ndash" to "\u2013",
            "mdash" to "\u2014",
            "hellip" to "\u2026",
            "lsquo" to "\u2018",
            "rsquo" to "\u2019",
            "ldquo" to "\u201C",
            "rdquo" to "\u201D",
            "copy" to "\u00A9",
            "reg" to "\u00AE",
            "trade" to "\u2122",
            "middot" to "\u00B7",
            "bull" to "\u2022",
        )
    private val WHITESPACE = Regex("""[\s\u00A0]+""")

    /** Tags whose contents are not prose; [firstLine] skips past their closing tag. */
    private val SKIPPED_TAGS = setOf("script", "style", "head")

    /**
     * Tags that start or end a line of prose. Inline tags (`a`, `b`, `em`,
     * `span`, …) are deliberately absent so "wor<b>d</b>" stays a word.
     */
    private val BLOCK_TAGS =
        setOf(
            "address",
            "article",
            "aside",
            "blockquote",
            "body",
            "br",
            "dd",
            "details",
            "div",
            "dl",
            "dt",
            "fieldset",
            "figcaption",
            "figure",
            "footer",
            "form",
            "h1",
            "h2",
            "h3",
            "h4",
            "h5",
            "h6",
            "header",
            "hr",
            "html",
            "li",
            "main",
            "nav",
            "ol",
            "p",
            "pre",
            "section",
            "summary",
            "table",
            "tbody",
            "td",
            "tfoot",
            "th",
            "thead",
            "tr",
            "ul",
        )

    fun toPlainText(html: String): String {
        var text = DROP.replace(html, "")
        text = BREAK.replace(text, "\n")
        text = BLOCK_END.replace(text, "\n")
        text = TAG.replace(text, "")
        return decodeEntities(text)
            .lines()
            .map { it.trim() }
            .joinToString("\n")
            .replace(Regex("\n{3,}"), "\n\n")
            .trim()
    }

    /**
     * The first line of prose in an HTML body, for a list row's preview
     * line. Block-level tags (`p`, `div`, `br`, `li`, headings, cells, …)
     * end a line, inline tags vanish, script/style/head/comments are
     * skipped, entities decode, and whitespace collapses to single spaces.
     * The scan stops as soon as the line is complete, so the cost is the
     * distance to the first prose rather than the size of the body — cheap
     * enough to call from a row. A line longer than [maxLength] is cut
     * there with an ellipsis; the row's own tail truncation handles the
     * column width. Returns "" when the body has no prose.
     */
    fun firstLine(
        html: String,
        maxLength: Int = 500,
    ): String {
        // Raw budget: the scan stops once this much markup-free text is in
        // hand; decoding and collapsing can only shrink it from there.
        val rawBudget = maxLength * 4
        val raw = StringBuilder()
        var cutShort = false
        val n = html.length
        var i = 0

        fun append(
            start: Int,
            end: Int,
        ) {
            if (cutShort || start >= end) return
            val room = rawBudget - raw.length
            if (end - start > room) {
                raw.append(html, start, start + room)
                cutShort = true
            } else {
                raw.append(html, start, end)
            }
        }

        fun hasProse(): Boolean = decodeEntities(raw.toString()).any { !it.isWhitespace() && it != '\u00A0' }

        while (i < n) {
            val lt = html.indexOf('<', i)
            if (lt < 0) {
                append(i, n)
                break
            }
            append(i, lt)
            if (cutShort) break
            if (html.startsWith("<!--", lt)) {
                val close = html.indexOf("-->", lt + 4)
                if (close < 0) break
                i = close + 3
                continue
            }
            var nameStart = lt + 1
            if (nameStart < n && html[nameStart] == '/') nameStart++
            var nameEnd = nameStart
            if (nameEnd < n && html[nameEnd].isLetter()) {
                while (nameEnd < n && html[nameEnd].isLetterOrDigit()) nameEnd++
            }
            if (nameEnd == nameStart) {
                // A bare `<` in prose ("a < b", "I <3 feeds"), not a tag: a
                // tag name starts with a letter.
                append(lt, lt + 1)
                i = lt + 1
                continue
            }
            val name = html.substring(nameStart, nameEnd).lowercase()
            val gt = html.indexOf('>', nameEnd)
            if (gt < 0) {
                // An unterminated pseudo-tag is prose too, as in [toPlainText].
                append(lt, n)
                break
            }
            i = gt + 1
            if (name in SKIPPED_TAGS) {
                val close = html.indexOf("</$name", i, ignoreCase = true)
                val closeGt = if (close < 0) -1 else html.indexOf('>', close)
                if (closeGt < 0) break
                i = closeGt + 1
            } else if (name in BLOCK_TAGS) {
                if (hasProse()) break
                raw.setLength(0)
            }
        }

        var text = decodeEntities(raw.toString()).replace(WHITESPACE, " ").trim()
        if (text.length > maxLength) {
            text = text.substring(0, maxLength).trimEnd()
            cutShort = true
        }
        return if (cutShort && text.isNotEmpty()) "$text\u2026" else text
    }

    private fun decodeEntities(text: String): String =
        ENTITY.replace(text) { match ->
            val token = match.groupValues[1]
            when {
                token.startsWith("#x") || token.startsWith("#X") ->
                    token.drop(2).toIntOrNull(16)?.let { codePoint(it) } ?: match.value
                token.startsWith("#") ->
                    token.drop(1).toIntOrNull()?.let { codePoint(it) } ?: match.value
                else -> NAMED[token] ?: match.value
            }
        }

    private fun codePoint(value: Int): String? = runCatching { String(Character.toChars(value)) }.getOrNull()
}

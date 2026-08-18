package com.cabalmail.kit.compose

/**
 * Best-effort HTML → plain text for quoting an HTML-only original in a
 * reply. Not a renderer: drops scripts/styles, turns block boundaries into
 * line breaks, strips every other tag, and decodes the common entities.
 * Good enough for an attribution block; the recipient's own client still
 * renders whatever the user types above it.
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
        )

    fun toPlainText(html: String): String {
        var text = DROP.replace(html, "")
        text = BREAK.replace(text, "\n")
        text = BLOCK_END.replace(text, "\n")
        text = TAG.replace(text, "")
        text =
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
        return text
            .lines()
            .map { it.trim() }
            .joinToString("\n")
            .replace(Regex("\n{3,}"), "\n\n")
            .trim()
    }

    private fun codePoint(value: Int): String? = runCatching { String(Character.toChars(value)) }.getOrNull()
}

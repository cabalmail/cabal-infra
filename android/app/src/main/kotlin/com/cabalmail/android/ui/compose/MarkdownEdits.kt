package com.cabalmail.android.ui.compose

/** Body-toolbar actions over the Markdown buffer (plan §5.1). */
enum class MarkdownAction { BOLD, ITALIC, LINK, BULLETS, NUMBERS, QUOTE, CODE }

/** A text buffer plus selection, decoupled from Compose for testability. */
data class TextSelection(
    val text: String,
    val start: Int,
    val end: Int,
)

/**
 * Pure Markdown editing operations behind the compose toolbar: inline
 * actions wrap the selection (or insert a placeholder and select it) and
 * block actions prefix every line the selection touches.
 */
object MarkdownEdits {
    fun apply(
        action: MarkdownAction,
        value: TextSelection,
    ): TextSelection {
        val text = value.text
        val start = minOf(value.start, value.end).coerceIn(0, text.length)
        val end = maxOf(value.start, value.end).coerceIn(0, text.length)
        val selected = text.substring(start, end)
        return when (action) {
            MarkdownAction.BOLD -> wrap(text, start, end, selected, "**", "bold")
            MarkdownAction.ITALIC -> wrap(text, start, end, selected, "_", "italic")
            MarkdownAction.CODE -> wrap(text, start, end, selected, "`", "code")
            MarkdownAction.LINK -> {
                val label = selected.ifEmpty { "link text" }
                val url = "https://"
                val replacement = "[$label]($url)"
                val urlStart = start + label.length + 3
                TextSelection(text.replaceRange(start, end, replacement), urlStart, urlStart + url.length)
            }
            MarkdownAction.BULLETS -> prefixLines(text, start, end) { "- " }
            MarkdownAction.NUMBERS -> prefixLines(text, start, end) { index -> "${index + 1}. " }
            MarkdownAction.QUOTE -> prefixLines(text, start, end) { "> " }
        }
    }

    private fun wrap(
        text: String,
        start: Int,
        end: Int,
        selected: String,
        marker: String,
        placeholder: String,
    ): TextSelection {
        val inner = selected.ifEmpty { placeholder }
        val replaced = text.replaceRange(start, end, "$marker$inner$marker")
        val innerStart = start + marker.length
        return TextSelection(replaced, innerStart, innerStart + inner.length)
    }

    private fun prefixLines(
        text: String,
        start: Int,
        end: Int,
        prefix: (Int) -> String,
    ): TextSelection {
        val lineStart = text.lastIndexOf('\n', start - 1).let { if (it < 0) 0 else it + 1 }
        val lineEndRaw = text.indexOf('\n', end.coerceAtLeast(lineStart))
        val lineEnd = if (lineEndRaw < 0) text.length else lineEndRaw
        val block = text.substring(lineStart, lineEnd)
        val rebuilt = block.split('\n').mapIndexed { index, line -> prefix(index) + line }.joinToString("\n")
        val replaced = text.replaceRange(lineStart, lineEnd, rebuilt)
        val caret = lineStart + rebuilt.length
        return TextSelection(replaced, caret, caret)
    }
}

package com.cabalmail.android.ui.mail

import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.LinkAnnotation
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextLinkStyles
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.style.TextDecoration

/**
 * A tappable range detected in a plain-text body. [url] is what the link
 * menu acts on and may differ from the visible substring (`www.` hosts get
 * an `https://` prefix, addresses become `mailto:`), mirroring the Apple
 * client's data-detector pass over plain text.
 */
internal data class PlainTextLinkSpan(
    val start: Int,
    val end: Int,
    val url: String,
)

// `<>` excluded so the plain-text convention of wrapping URLs in angle
// brackets doesn't drag the closing bracket into the link.
private val URL_PATTERN = Regex("""\bhttps?://[^\s<>]+""", RegexOption.IGNORE_CASE)
private val WWW_PATTERN = Regex("""\bwww\.[^\s<>]+""", RegexOption.IGNORE_CASE)
private val EMAIL_PATTERN = Regex("""[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}""")

/**
 * Finds web URLs, `www.` hosts, and email addresses in [text], returning
 * non-overlapping spans in document order. Trailing sentence punctuation
 * (and closing brackets with no opening partner inside the match) is left
 * out of the link, so "see https://example.com." links the URL alone.
 */
internal fun plainTextLinkSpans(text: String): List<PlainTextLinkSpan> {
    val spans = mutableListOf<PlainTextLinkSpan>()

    fun addMatches(
        pattern: Regex,
        toUrl: (String) -> String?,
    ) {
        pattern.findAll(text).forEach { match ->
            val visible = trimTrailingPunctuation(match.value)
            if (visible.isEmpty()) {
                return@forEach
            }
            val start = match.range.first
            val end = start + visible.length
            if (spans.any { it.start < end && start < it.end }) {
                return@forEach
            }
            toUrl(visible)?.let { spans += PlainTextLinkSpan(start = start, end = end, url = it) }
        }
    }

    addMatches(URL_PATTERN) { candidate ->
        candidate.takeIf { it.substringAfter("://", "").isNotEmpty() }
    }
    addMatches(WWW_PATTERN) { candidate ->
        // Needs a dot beyond the prefix — a bare "www.foo" is more likely prose.
        candidate.takeIf { it.removePrefix("www.").contains('.') }?.let { "https://$it" }
    }
    addMatches(EMAIL_PATTERN) { candidate -> "mailto:$candidate" }
    return spans.sortedBy { it.start }
}

private fun trimTrailingPunctuation(candidate: String): String {
    var result = candidate
    while (result.isNotEmpty()) {
        val strip =
            when (result.last()) {
                '.', ',', ';', ':', '!', '?', '\'', '"' -> true
                ')' -> '(' !in result
                ']' -> '[' !in result
                '}' -> '{' !in result
                else -> false
            }
        if (!strip) {
            break
        }
        result = result.dropLast(1)
    }
    return result
}

/**
 * The plain-text sibling of `HtmlBody`: selectable text whose detected
 * links feed the same [LinkMenuSheet] flow via [onLinkTap] instead of
 * navigating anywhere.
 */
@Composable
internal fun PlainTextBody(
    text: String,
    onLinkTap: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    val currentOnLinkTap by rememberUpdatedState(onLinkTap)
    val linkColor = MaterialTheme.colorScheme.primary
    val annotated =
        remember(text, linkColor) {
            val styles =
                TextLinkStyles(
                    style = SpanStyle(color = linkColor, textDecoration = TextDecoration.Underline),
                )
            buildAnnotatedString {
                append(text)
                plainTextLinkSpans(text).forEach { span ->
                    addLink(
                        LinkAnnotation.Clickable(
                            tag = span.url,
                            styles = styles,
                            linkInteractionListener = { currentOnLinkTap(span.url) },
                        ),
                        span.start,
                        span.end,
                    )
                }
            }
        }
    SelectionContainer(modifier = modifier) {
        Text(text = annotated, style = MaterialTheme.typography.bodyMedium)
    }
}

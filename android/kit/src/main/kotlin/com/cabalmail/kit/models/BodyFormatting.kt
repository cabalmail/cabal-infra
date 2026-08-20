package com.cabalmail.kit.models

// HTML body transforms for the reader. Pure string functions so the app
// layer's WebView wrapper stays dumb and this logic stays unit-tested.

private val CID_SRC = Regex("""src\s*=\s*["']cid:([^"']+)["']""", RegexOption.IGNORE_CASE)

/** Distinct Content-IDs referenced as `src="cid:..."` in [html]. */
fun inlineContentIds(html: String): List<String> =
    CID_SRC
        .findAll(html)
        .map { it.groupValues[1] }
        .distinct()
        .toList()

/**
 * Rewrites `src="cid:..."` references through [resolved] (Content-ID to
 * URI, typically a `data:` URI built from `/fetch_inline_image`).
 * Unresolved references are left untouched — a broken image beats a
 * dropped one.
 */
fun resolveInlineImages(
    html: String,
    resolved: Map<String, String>,
): String =
    CID_SRC.replace(html) { match ->
        resolved[match.groupValues[1]]?.let { "src=\"$it\"" } ?: match.value
    }

private val AUTHOR_STYLE_BLOCK =
    Regex("""<style\b[^>]*>[\s\S]*?</style\s*>""", RegexOption.IGNORE_CASE)
private val AUTHOR_STYLESHEET_LINK =
    Regex("""<link\b[^>]*\brel\s*=\s*["']?\s*stylesheet\b[^>]*>""", RegexOption.IGNORE_CASE)

/**
 * The Reader render mode: author markup kept, author styling replaced
 * with a system-font, capped-line-length, [darkMode]-aware stylesheet.
 * Author `<style>` blocks and stylesheet `<link>`s are removed rather
 * than out-cascaded: a trailing `!important` element selector only beats
 * author rules of equal specificity, and marketing emails routinely carry
 * `@media (max-width: ...)` class rules (`.wrapper { background: #fff
 * !important }`) that would win at phone widths and paint light
 * backgrounds under the dark palette. Inline `style=` attributes stay and
 * are overridden by the trailing `!important` stylesheet.
 */
fun readerModeHtml(
    html: String,
    darkMode: Boolean,
): String {
    val stripped =
        html
            .replace(AUTHOR_STYLE_BLOCK, "")
            .replace(AUTHOR_STYLESHEET_LINK, "")
    val foreground = if (darkMode) "#e4e2dd" else "#1a1c1a"
    val background = if (darkMode) "#121412" else "#fdfcf8"
    val link = if (darkMode) "#9ccc9c" else "#2e6b30"
    return """
        <meta name="viewport" content="width=device-width, initial-scale=1">
        $stripped
        <style>
          html { background: $background !important; }
          body {
            margin: 0 auto !important; padding: 16px !important; max-width: 70ch !important;
            font-family: system-ui, sans-serif !important;
            font-size: 17px !important; line-height: 1.5 !important;
            color: $foreground !important; background: $background !important;
          }
          body * {
            font-family: inherit !important; color: inherit !important;
            background: transparent !important; font-size: inherit !important;
            line-height: inherit !important; max-width: 100% !important;
          }
          img { max-width: 100% !important; height: auto !important; }
          a { color: $link !important; }
          pre, code { white-space: pre-wrap !important; word-break: break-word !important; }
        </style>
        """.trimIndent()
}

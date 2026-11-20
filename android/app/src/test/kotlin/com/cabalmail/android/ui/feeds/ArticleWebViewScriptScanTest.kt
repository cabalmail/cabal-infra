package com.cabalmail.android.ui.feeds

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import java.io.File

/**
 * Where the app's web views get their JavaScript setting, and where the
 * feed article view starts a load. `ArticleReaderTest` holds the rule (the
 * reader document loads with scripts off, everything else with them on)
 * against a recorded web view; a `WebView` itself has no unit-test seam,
 * so these hold the source to going through that rule and nothing else.
 * Gradle runs unit tests from the module directory, so the repository root
 * is two levels up.
 */
class ArticleWebViewScriptScanTest {
    private val mainSources: File =
        File(File("../..").canonicalFile, "android/app/src/main/kotlin/com/cabalmail/android")

    /** Block and line comments cut, so prose naming a call is not a use of it. */
    private fun code(text: String): String =
        text.replace(Regex("""(?s)/\*.*?\*/"""), "").lines().joinToString("\n") { it.substringBefore("//") }

    private val scriptSetting = Regex("""(?i)javaScriptEnabled""")

    /** A call on a web view that puts a page on screen or runs script in one. */
    private val pageCall =
        Regex(
            """\.(loadUrl|loadData|loadDataWithBaseURL|postUrl|reload|goBack|goForward|goBackOrForward|evaluateJavascript)\(""",
        )

    @Test
    fun `a web view's JavaScript is set in these places and no others`() {
        val files = mainSources.walkTopDown().filter { it.extension == "kt" }.toList()
        assertTrue(files.size > 80, "scanned only ${files.size} files; is the source root right?")
        val uses =
            files
                .sortedBy { it.relativeTo(mainSources).path }
                .flatMap { file ->
                    code(file.readText())
                        .lines()
                        .filter { scriptSetting.containsMatchIn(it) }
                        .map { "${file.relativeTo(mainSources).path}: ${it.trim()}" }
                }
        // The article view: ArticleReader decides, per load, through the one
        // adapter over the web view, which is also the one place Android
        // Lint's warning about the setting is answered. The mail reader and
        // the feed summary: never on. A new line here is a web view running
        // page script; the reader rendering of a feed article and the mail
        // reader must not.
        assertEquals(
            listOf(
                "ui/feeds/ArticleReader.kt: fun setJavaScriptEnabled(enabled: Boolean)",
                "ui/feeds/ArticleReader.kt: page.setJavaScriptEnabled(ArticleScriptPolicy.allowsJavaScript(load))",
                "ui/feeds/ArticleWebView.kt: @SuppressLint(\"SetJavaScriptEnabled\")",
                "ui/feeds/ArticleWebView.kt: override fun setJavaScriptEnabled(enabled: Boolean) {",
                "ui/feeds/ArticleWebView.kt: view.settings.javaScriptEnabled = enabled",
                "ui/mail/MessageDetailScreen.kt: settings.javaScriptEnabled = false",
            ),
            uses,
        )
    }

    @Test
    fun `the article view loads pages only through the reader's adapter`() {
        val source = code(File(mainSources, "ui/feeds/ArticleWebView.kt").readText())
        val start = source.indexOf("private class WebViewArticlePage(")
        assertTrue(start >= 0, "the adapter over the web view is gone; where do the article view's loads go now?")
        val end = source.indexOf("\n}\n", start)
        assertTrue(end > start, "the adapter's closing brace was not found")
        val adapter = source.substring(start, end)
        val rest = source.removeRange(start, end)
        assertEquals(
            emptyList<String>(),
            rest.lines().filter { pageCall.containsMatchIn(it) }.map { it.trim() },
            "a load started outside ArticleReader skips the JavaScript setting it makes first",
        )
        // And the adapter is `WebView`'s calls one for one: no load of its own choosing.
        assertEquals(
            listOf("loadUrl", "loadDataWithBaseURL", "goBack", "evaluateJavascript"),
            pageCall.findAll(adapter).map { it.groupValues[1] }.toList(),
        )
    }

    @Test
    fun `the detector matches a load and ignores a question and prose`() {
        assertTrue(pageCall.containsMatchIn(code("view.loadUrl(url)")))
        assertTrue(pageCall.containsMatchIn(code("webView?.goBack()")))
        assertTrue(pageCall.containsMatchIn(code("view.loadDataWithBaseURL(a, b, c, d, e)")))
        assertFalse(pageCall.containsMatchIn(code("canGoBack = view?.canGoBack() == true")))
        assertFalse(pageCall.containsMatchIn(code("reader.back(page) // not view.goBack()")))
        assertFalse(pageCall.containsMatchIn(code("/** calls `view.loadUrl(url)` */\nfun f() = 1")))
        assertTrue(scriptSetting.containsMatchIn(code("settings.setJavaScriptEnabled(true)")))
        assertTrue(scriptSetting.containsMatchIn(code("with(settings) { javaScriptEnabled = true }")))
    }
}

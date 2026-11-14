package com.cabalmail.kit.settings

import java.text.BreakIterator

/**
 * The rules `set_preferences` holds the typed settings to
 * (`lambda/api/set_preferences/function.py`): a flag's name, the signature
 * and the display name. The server refuses the whole request, with a 400,
 * when one value breaks them, and this app sends them all in one request,
 * so [PreferencesRepository] keeps every value it holds within them, on
 * each write and each read of the store (#2453). The Kotlin sibling of the
 * Apple kit's `ServerTextRules`.
 *
 * The server counts with Python's `len()`, which counts Unicode code
 * points. `String.length` and `take` count UTF-16 units, so they neither
 * match the server's count nor keep a character whole. These cut by code
 * points, and at a character boundary, so no character is split.
 */
object ServerTextRules {
    /** The longest signature the server takes, in code points (`MAX_SIGNATURE_LENGTH`). */
    const val MAX_SIGNATURE_LENGTH = 2000

    /** The longest display name the server takes, in code points (`MAX_NAME_LENGTH`). */
    const val MAX_NAME_LENGTH = 100

    private const val FIRST_PRINTABLE = 0x20
    private const val DELETE = 0x7F

    /**
     * A flag's name as the server takes it: control characters (below
     * U+0020, and U+007F) dropped, then cut to
     * [FlagPalette.MAX_LABEL_LENGTH] code points. It can come out empty,
     * which the server refuses too: the flag editor writes no such name,
     * and [FlagPalette.accepted] names an entry stored with one.
     */
    fun flagLabel(label: String): String = cut(keeping(label) { !isControl(it) }, FlagPalette.MAX_LABEL_LENGTH)

    /**
     * The signature as the server takes it: a CR LF or a lone CR becomes a
     * newline, other control characters but newline and tab are dropped,
     * and the rest is cut to [MAX_SIGNATURE_LENGTH] code points.
     */
    fun signature(signature: String): String {
        val lines = signature.replace("\r\n", "\n").replace('\r', '\n')
        val kept = keeping(lines) { it == '\n'.code || it == '\t'.code || !isControl(it) }
        return cut(kept, MAX_SIGNATURE_LENGTH)
    }

    /**
     * The display name as the server takes it: control characters dropped,
     * trimmed as the server trims it, and cut to [MAX_NAME_LENGTH] code
     * points. Empty means no display name, which the server takes.
     */
    fun displayName(name: String): String = cut(keeping(name) { !isControl(it) }.trim(), MAX_NAME_LENGTH).trim()

    /**
     * The longest run of whole characters from the start of [text] whose
     * code points number [limit] or fewer.
     */
    internal fun cut(
        text: String,
        limit: Int,
    ): String {
        if (text.codePointCount(0, text.length) <= limit) return text
        val characters = BreakIterator.getCharacterInstance()
        characters.setText(text)
        var end = 0
        var kept = 0
        var next = characters.next()
        while (next != BreakIterator.DONE) {
            val codePoints = text.codePointCount(end, next)
            if (kept + codePoints > limit) break
            kept += codePoints
            end = next
            next = characters.next()
        }
        return text.substring(0, end)
    }

    private fun isControl(codePoint: Int): Boolean = codePoint < FIRST_PRINTABLE || codePoint == DELETE

    private fun keeping(
        text: String,
        include: (Int) -> Boolean,
    ): String {
        val kept = StringBuilder(text.length)
        text.codePoints().filter { include(it) }.forEach { kept.appendCodePoint(it) }
        return kept.toString()
    }
}

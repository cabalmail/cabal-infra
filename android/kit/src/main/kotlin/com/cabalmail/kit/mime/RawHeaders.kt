package com.cabalmail.kit.mime

/**
 * Minimal RFC 5322 header-block reader. The `/fetch_message` response
 * carries the decoded bodies and the threading ids but not every header
 * (notably `Bcc`, which a resumed draft needs); those come from the top of
 * the raw message the `message_raw` presigned URL serves.
 *
 * Handles folding (continuation lines starting with whitespace) and stops
 * at the first blank line. Values are returned raw — no RFC 2047 decoding,
 * which the address list and message-id consumers here do not need.
 */
object RawHeaders {
    data class Header(
        val name: String,
        val value: String,
    )

    /** Parses the header block at the top of [raw]; body text is ignored. */
    fun parse(raw: String): List<Header> {
        val headers = mutableListOf<Header>()
        var name: String? = null
        val value = StringBuilder()

        fun flush() {
            name?.let { headers.add(Header(it, value.toString().trim())) }
            name = null
            value.setLength(0)
        }
        for (line in raw.lineSequence()) {
            if (line.isEmpty()) {
                break
            }
            if (line[0] == ' ' || line[0] == '\t') {
                if (name != null) {
                    value.append(' ').append(line.trim())
                }
                continue
            }
            flush()
            val colon = line.indexOf(':')
            if (colon <= 0) {
                continue
            }
            name = line.substring(0, colon).trim()
            value.append(line.substring(colon + 1).trim())
        }
        flush()
        return headers
    }

    /** First value of [name], case-insensitively, or null. */
    fun List<Header>.valueOf(name: String): String? = firstOrNull { it.name.equals(name, ignoreCase = true) }?.value

    /**
     * Splits an address-list header value (`a@x, "B, Inc" <b@y>`) into bare
     * `mailbox@host` strings, honouring quoted display names that contain
     * commas.
     */
    fun addressList(raw: String?): List<String> {
        if (raw.isNullOrBlank()) {
            return emptyList()
        }
        val tokens = mutableListOf<String>()
        val current = StringBuilder()
        var quoted = false
        var depth = 0
        for (ch in raw) {
            when {
                ch == '"' -> {
                    quoted = !quoted
                    current.append(ch)
                }
                !quoted && ch == '<' -> {
                    depth += 1
                    current.append(ch)
                }
                !quoted && ch == '>' -> {
                    depth -= 1
                    current.append(ch)
                }
                !quoted && depth == 0 && ch == ',' -> {
                    tokens.add(current.toString())
                    current.setLength(0)
                }
                else -> current.append(ch)
            }
        }
        tokens.add(current.toString())
        return tokens.mapNotNull { token ->
            val trimmed = token.trim()
            val open = trimmed.lastIndexOf('<')
            val close = trimmed.lastIndexOf('>')
            if (open >= 0 && close > open) {
                trimmed.substring(open + 1, close).trim().takeIf { it.isNotEmpty() }
            } else {
                trimmed.takeIf { it.isNotEmpty() }
            }
        }
    }
}

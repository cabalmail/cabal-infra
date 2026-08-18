package com.cabalmail.kit.compose

import java.util.UUID

/**
 * RFC 5322 message-id plumbing. Drafts and [ReplyBuilder] carry bare ids;
 * the wire (`other_headers`) carries angle-bracketed ones and the Lambda
 * writes them verbatim, so [angleWrapped] is the one seam every sender
 * passes through.
 */
object MessageIds {
    private val TOKEN = Regex("""<[^<>\s]+>""")

    /** Strips one pair of surrounding angle brackets and whitespace. */
    fun bare(id: String): String = id.trim().removePrefix("<").removeSuffix(">").trim()

    /**
     * Wraps a bare id in angle brackets unless it already carries them;
     * blank tokens map to null so they drop off the wire entirely.
     */
    fun angleWrapped(id: String?): String? {
        val trimmed = id?.trim().orEmpty()
        if (trimmed.isEmpty()) {
            return null
        }
        return if (trimmed.startsWith("<") && trimmed.endsWith(">")) trimmed else "<$trimmed>"
    }

    /**
     * Splits a raw header value (`References: <a@x> <b@y>`, possibly folded
     * onto several lines, possibly comma-separated by a sloppy client) into
     * bare ids in order. Tolerates values that are already a single bare
     * id with no brackets.
     */
    fun parse(raw: String?): List<String> {
        if (raw.isNullOrBlank()) {
            return emptyList()
        }
        val bracketed = TOKEN.findAll(raw).map { bare(it.value) }.toList()
        if (bracketed.isNotEmpty()) {
            return bracketed
        }
        return raw
            .split(Regex("""[\s,]+"""))
            .map { it.trim() }
            .filter { it.isNotEmpty() }
    }

    /** Parses each element of a raw-header list (see `MessageContent`) and flattens. */
    fun parseAll(values: List<String>?): List<String> = values.orEmpty().flatMap(::parse)

    /** A fresh `<uuid@host>` id, the shape the Apple client mints. */
    fun generate(senderHost: String): String = "<${UUID.randomUUID()}@$senderHost>"
}

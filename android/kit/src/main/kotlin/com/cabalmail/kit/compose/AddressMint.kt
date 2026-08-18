package com.cabalmail.kit.compose

import kotlin.random.Random

/**
 * Helpers for the "Create new address…" flow. Minting a fresh
 * relationship-scoped address is *the* Cabalmail idiom, so the form offers
 * a one-tap Random fill for users who do not want to name it themselves —
 * the same alphabet and length the React and Apple forms use.
 */
object AddressMint {
    const val LABEL_ALPHABET = "abcdefghijklmnopqrstuvwxyz0123456789"
    const val RANDOM_LABEL_LENGTH = 8

    fun randomLabel(
        length: Int = RANDOM_LABEL_LENGTH,
        random: Random = Random.Default,
    ): String = buildString(length) { repeat(length) { append(LABEL_ALPHABET[random.nextInt(LABEL_ALPHABET.length)]) } }

    /**
     * Normalizes free-form input into a token that passes the `/new`
     * Lambda's local-part / DNS-label validation: lowercased, whitespace
     * and `_`/`.` runs collapsed to single hyphens, anything else outside
     * `[a-z0-9-]` dropped, hyphens trimmed, capped at 63 chars. Null when
     * nothing usable survives.
     */
    fun normalizeLabel(raw: String): String? {
        val collapsed =
            raw
                .lowercase()
                .replace(Regex("""[\s_.]+"""), "-")
                .replace(Regex("""[^a-z0-9-]"""), "")
                .replace(Regex("-{2,}"), "-")
                .trim('-')
                .take(63)
                .trim('-')
        return collapsed.takeIf { it.isNotEmpty() }
    }
}

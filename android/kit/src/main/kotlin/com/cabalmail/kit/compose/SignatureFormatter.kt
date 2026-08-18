package com.cabalmail.kit.compose

/**
 * Inserts the plain-text signature into a compose seed, always introduced
 * by the RFC 3676 delimiter (`-- ` on its own line) so downstream clients
 * can collapse it. Mirrors the Apple `SignatureFormatter`:
 *
 * - new message (empty base): `\n-- \n<sig>` — cursor lands above it;
 * - reply / forward (base leads with `\n\n`): `-- \n<sig>` + base — the
 *   signature sits right before the attribution;
 * - anything else: `-- \n<sig>\n` + base.
 *
 * An empty signature is a no-op.
 */
object SignatureFormatter {
    fun seedBody(
        base: String,
        signature: String,
    ): String {
        if (signature.isEmpty()) {
            return base
        }
        val block = "\n-- \n$signature"
        return when {
            base.isEmpty() -> "\n$block"
            base.startsWith("\n\n") -> block + base
            else -> "$block\n$base"
        }
    }
}

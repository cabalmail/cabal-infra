package com.cabalmail.kit.rules

import com.cabalmail.kit.models.Rule
import com.cabalmail.kit.models.RuleCondition

/**
 * Client-side mirror of the `/set_rules` Lambda's write-time validation
 * (`lambda/api/set_rules/function.py`), the Kotlin sibling of the Apple
 * kit's `RulesValidator` — same checks, same messages, same corpus. The
 * editor flags a problem inline (and holds the debounced PUT) instead of
 * round-tripping for a 400.
 *
 * Lengths count Unicode code points to match Python's `len()` — Kotlin's
 * `String.length` is UTF-16 code units, which over-counts astral-plane
 * characters.
 *
 * One deliberate divergence: invalid forward addresses are *issues* here
 * but are silently stripped (not rejected) server-side — flagging them
 * client-side keeps the server's stripping a dead code path.
 */
object RulesValidator {
    const val MAX_RULES = 100
    const val MAX_NAME_LENGTH = 100
    const val MAX_CONDITIONS = 10
    const val MAX_VALUE_LENGTH = 500
    const val MAX_FORWARDS = 10
    const val MAX_COPY_FOLDERS = 10
    const val MAX_ADDRESS_LENGTH = 320
    const val MAX_REPLY_BODY_LENGTH = 4000
    const val MAX_FOLDER_LENGTH = 255

    /**
     * One structured finding, mirroring the Lambda's `{rule, field, error}`
     * entries. [ruleIndex] is null for set-level findings (the rule-count
     * cap).
     */
    data class Issue(
        val ruleIndex: Int?,
        val field: String,
        val message: String,
    )

    /**
     * Validates the whole ordered set; empty means the server will accept
     * it verbatim (no 400, nothing stripped).
     */
    fun validate(rules: List<Rule>): List<Issue> =
        buildList {
            if (rules.size > MAX_RULES) {
                add(Issue(ruleIndex = null, field = "rules", message = "At most $MAX_RULES rules."))
            }
            rules.forEachIndexed { index, rule -> addAll(validate(rule, index)) }
        }

    /** Validates one rule; [index] only labels the returned issues. */
    fun validate(
        rule: Rule,
        index: Int = 0,
    ): List<Issue> =
        scalarIssues(rule, index) +
            conditionIssues(rule.conditions, index) +
            copyFolderIssues(rule.copyFolders, index) +
            forwardIssues(rule.forward, index)

    /**
     * The Lambda's `FORWARD_RE` (`^[^\s@]+@[^\s@]+\.[^\s@]+$`) plus its
     * length and control-character checks: exactly one `@`, no whitespace,
     * and a dot in the domain that is neither its first nor last character.
     */
    fun isValidForwardAddress(address: String): Boolean {
        if (address.isEmpty() ||
            codePoints(address) > MAX_ADDRESS_LENGTH ||
            hasForbiddenControls(address) ||
            address.any { it.isWhitespace() }
        ) {
            return false
        }
        val parts = address.split("@")
        if (parts.size != 2 || parts[0].isEmpty()) {
            return false
        }
        val domain = parts[1]
        // The regex's domain shape reduces to: some dot that is neither the
        // domain's first nor last character.
        return domain.length >= 3 && domain.substring(1, domain.length - 1).contains('.')
    }

    private fun scalarIssues(
        rule: Rule,
        index: Int,
    ): List<Issue> =
        buildList {
            val trimmedName = rule.name.trim()
            if (trimmedName.isEmpty() || codePoints(trimmedName) > MAX_NAME_LENGTH || hasForbiddenControls(rule.name)) {
                add(
                    Issue(index, "name", "Must be 1-$MAX_NAME_LENGTH characters, no control characters."),
                )
            }
            folderIssue(rule.moveFolder)?.let { add(Issue(index, "moveFolder", it)) }
            if (codePoints(rule.replyBody) > MAX_REPLY_BODY_LENGTH ||
                hasForbiddenControls(rule.replyBody, allowNewlines = true)
            ) {
                add(
                    Issue(index, "replyBody", "Must be at most $MAX_REPLY_BODY_LENGTH characters; newlines only."),
                )
            } else if (rule.reply && rule.replyBody.isEmpty()) {
                add(Issue(index, "replyBody", "Required when reply is on."))
            }
        }

    private fun conditionIssues(
        conditions: List<RuleCondition>,
        index: Int,
    ): List<Issue> {
        if (conditions.size > MAX_CONDITIONS) {
            return listOf(Issue(index, "conditions", "At most $MAX_CONDITIONS conditions per rule."))
        }
        return conditions.mapIndexedNotNull { position, condition ->
            val count = codePoints(condition.value)
            if (count < 1 || count > MAX_VALUE_LENGTH || hasForbiddenControls(condition.value)) {
                Issue(
                    index,
                    "conditions[$position].value",
                    "Must be 1-$MAX_VALUE_LENGTH characters, no control characters.",
                )
            } else {
                null
            }
        }
    }

    private fun copyFolderIssues(
        folders: List<String>,
        index: Int,
    ): List<Issue> {
        if (folders.size > MAX_COPY_FOLDERS) {
            return listOf(Issue(index, "copyFolders", "At most $MAX_COPY_FOLDERS copy targets per rule."))
        }
        return folders.mapIndexedNotNull { position, folder ->
            val message = if (folder.isEmpty()) "Copy target must not be empty." else folderIssue(folder)
            message?.let { Issue(index, "copyFolders[$position]", it) }
        }
    }

    private fun forwardIssues(
        forwards: List<String>,
        index: Int,
    ): List<Issue> =
        buildList {
            if (forwards.size > MAX_FORWARDS) {
                add(Issue(index, "forward", "At most $MAX_FORWARDS forward addresses per rule."))
            }
            forwards.forEachIndexed { position, address ->
                if (!isValidForwardAddress(address)) {
                    add(Issue(index, "forward[$position]", "Not a valid email address."))
                }
            }
        }

    /**
     * The Lambda's `_folder_error`: empty is allowed (destination not
     * picked yet — the compiler skips with `folder_not_set`), otherwise
     * bounded, control-free, without procmail-meaningful characters, and a
     * relative path with no `..`.
     */
    internal fun folderIssue(folder: String): String? =
        when {
            folder.isEmpty() -> null
            codePoints(folder) > MAX_FOLDER_LENGTH -> "Folder name exceeds $MAX_FOLDER_LENGTH characters."
            hasForbiddenControls(folder) || folder.any { it in "|>`" } ->
                "Folder name contains a forbidden character."
            folder.startsWith("/") || folder.contains("..") ->
                "Folder name must be a relative path without \"..\"."
            else -> null
        }

    /**
     * The Lambda's `_bad_controls`: code points below 0x20 (except `\n`
     * when allowed) and DEL (0x7F).
     */
    internal fun hasForbiddenControls(
        value: String,
        allowNewlines: Boolean = false,
    ): Boolean =
        value.codePoints().anyMatch { code ->
            (code < 0x20 && !(allowNewlines && code == '\n'.code)) || code == 0x7F
        }

    private fun codePoints(value: String): Int = value.codePointCount(0, value.length)
}

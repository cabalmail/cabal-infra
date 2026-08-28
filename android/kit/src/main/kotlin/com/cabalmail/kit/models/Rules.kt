package com.cabalmail.kit.models

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

// Wire models for the user-mail-rules endpoints (`/get_rules` /
// `/set_rules`; docs/1.x/user-mail-rules-plan.md), matching the Apple kit's
// Rule/RuleSet shape. Missing keys decode as the Lambda normalizer's
// defaults; an unknown field/action value still fails the decode
// deliberately — silently coercing it would rewrite the rule on the next
// whole-set save.

/**
 * Condition fields. Five, not six: BCC recipients are stripped before a
 * message is transmitted, so a BCC condition would silently never match
 * (the plan's "BCC is not offered").
 */
@Serializable
enum class RuleField {
    @SerialName("from")
    FROM,

    @SerialName("to")
    TO,

    @SerialName("cc")
    CC,

    @SerialName("subject")
    SUBJECT,

    @SerialName("body")
    BODY,
}

/**
 * The mutually-exclusive destination. [NONE] is the no-destination case
 * (auxiliary actions still run); [ARCHIVE] targets the user's existing
 * `Archive` folder and is skipped by the compiler when there isn't one.
 */
@Serializable
enum class RuleAction {
    @SerialName("move")
    MOVE,

    @SerialName("copy")
    COPY,

    @SerialName("delete")
    DELETE,

    @SerialName("archive")
    ARCHIVE,

    @SerialName("none")
    NONE,
}

/**
 * One trigger clause; a rule's conditions are ANDed and the only operator
 * is case-insensitive contains. An empty list matches every message.
 */
@Serializable
data class RuleCondition(
    val field: RuleField = RuleField.FROM,
    val value: String = "",
)

/**
 * One user-defined mail rule. Precedence is positional — the index in
 * [RuleSet.rules] is the evaluation order, so a reorder is just splicing
 * the list and saving the whole set.
 *
 * [id] is server-assigned (`r-` + 12 hex); the Lambda keeps a well-formed,
 * unseen client id so edits stay stable across saves, which is why new
 * local rules mint one via [mintRuleId].
 */
@Serializable
data class Rule(
    val id: String = mintRuleId(),
    val name: String = "",
    val enabled: Boolean = true,
    val conditions: List<RuleCondition> = emptyList(),
    val action: RuleAction = RuleAction.NONE,
    /** Move destination; `/`-delimited display path, as `/list_folders` returns. */
    val moveFolder: String = "",
    val copyFolders: List<String> = emptyList(),
    val flag: Boolean = false,
    val markRead: Boolean = false,
    val forward: List<String> = emptyList(),
    val reply: Boolean = false,
    /** Plain text; required non-empty when [reply] is on. */
    val replyBody: String = "",
    /** Spill-through: keep evaluating later rules after this one fires. */
    val continueToNext: Boolean = false,
)

/**
 * The whole ordered rule set as returned by `/get_rules` and `/set_rules`:
 * one row per user, [version] carrying optimistic concurrency.
 */
@Serializable
data class RuleSet(
    val rules: List<Rule> = emptyList(),
    val version: Int = 0,
    /** ISO 8601 server stamp; informational. */
    val updatedAt: String = "",
)

/**
 * A fresh id in the server's `r-` + 12 lowercase hex format. A drifting
 * local format would be re-minted server-side on every save, breaking
 * stable editing.
 */
fun mintRuleId(): String = "r-" + List(12) { "0123456789abcdef".random() }.joinToString("")

/**
 * Truthful-Continue normalization
 * (`docs/1.x/rules-composition-and-custom-flags-plan.md`, decision 2). A
 * stored `move`/`archive` with spill-through predates the gated editor; the
 * compiler emits the exact same copy block for it as for `copy`, so the
 * editors render and save it as the Copy it is (Archive is an implicit move
 * to the `Archive` folder, so that is the folder the copy carries over). A
 * stored `delete` with spill-through drops the flag the compiler ignores.
 * One-way and silent — the server and compiler stay permissive, so a set
 * that is never re-saved keeps working unchanged.
 */
fun Rule.normalizeLegacyContinue(): Rule =
    when {
        !continueToNext -> this
        action == RuleAction.MOVE ->
            copy(
                action = RuleAction.COPY,
                copyFolders = if (moveFolder.isEmpty()) emptyList() else listOf(moveFolder),
            )
        action == RuleAction.ARCHIVE -> copy(action = RuleAction.COPY, copyFolders = listOf("Archive"))
        action == RuleAction.DELETE -> copy(continueToNext = false)
        else -> this
    }

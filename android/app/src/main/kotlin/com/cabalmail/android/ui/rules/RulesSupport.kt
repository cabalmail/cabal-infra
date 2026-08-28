package com.cabalmail.android.ui.rules

import com.cabalmail.kit.models.Rule
import com.cabalmail.kit.models.RuleAction
import com.cabalmail.kit.models.RuleCondition
import com.cabalmail.kit.models.RuleField

/**
 * The plan's quick-start templates. All start disabled: each needs a user
 * decision (a destination folder, the real sender, the reply wording)
 * before it should act on mail — and the placeholder values keep the set
 * valid, so a fresh template never wedges the validation-gated auto-save.
 */
object RuleTemplates {
    fun fileReceipts(): Rule =
        Rule(
            name = "File AWS receipts",
            enabled = false,
            conditions = listOf(RuleCondition(RuleField.FROM, "aws.amazon.com")),
            action = RuleAction.MOVE,
        )

    fun muteNewsletter(): Rule =
        Rule(
            name = "Mute a newsletter",
            enabled = false,
            conditions = listOf(RuleCondition(RuleField.FROM, "newsletter@example.com")),
            action = RuleAction.ARCHIVE,
            markRead = true,
        )

    fun vacationReply(): Rule =
        Rule(
            name = "Vacation reply",
            enabled = false,
            reply = true,
            replyBody = "I'm away right now and will reply when I return.",
        )
}

/**
 * One-line rule summary for the list rows — the same shape the Apple
 * client's `RuleSummary` renders. Pure so it unit-tests without Compose.
 */
fun describeRule(rule: Rule): String {
    val parts = mutableListOf(conditionsPhrase(rule.conditions))
    // A continuing None rule neither files nor stops; "no filing" would
    // just be noise, so a decorate-only rule reads "flag · continue".
    if (!(rule.action == RuleAction.NONE && rule.continueToNext)) {
        parts += actionPhrase(rule)
    }
    if (rule.flag) parts += "flag"
    if (rule.markRead) parts += "mark read"
    if (rule.forward.isNotEmpty()) parts += "forward to ${rule.forward.joinToString(", ")}"
    if (rule.reply) parts += "reply"
    // "continue" last, so a spill-through rule reads as what it is:
    // "copy to Receipts · continue" (truthful Continue, Phase 1).
    if (rule.continueToNext) parts += "continue"
    return parts.joinToString(" · ")
}

private fun conditionsPhrase(conditions: List<RuleCondition>): String {
    val first = conditions.firstOrNull() ?: return "Every message"
    val phrase = "${fieldName(first.field)} contains “${first.value}”"
    val rest = conditions.size - 1
    return if (rest > 0) "$phrase + $rest more" else phrase
}

private fun actionPhrase(rule: Rule): String =
    when (rule.action) {
        RuleAction.MOVE ->
            if (rule.moveFolder.isEmpty()) "move (pick a folder)" else "move to ${rule.moveFolder}"
        RuleAction.COPY ->
            if (rule.copyFolders.isEmpty()) "copy (pick folders)" else "copy to ${rule.copyFolders.joinToString(", ")}"
        RuleAction.DELETE -> "delete"
        RuleAction.ARCHIVE -> "archive"
        RuleAction.NONE -> "no filing"
    }

private fun fieldName(field: RuleField): String =
    when (field) {
        RuleField.FROM -> "From"
        RuleField.TO -> "To"
        RuleField.CC -> "Cc"
        RuleField.SUBJECT -> "Subject"
        RuleField.BODY -> "Body"
    }

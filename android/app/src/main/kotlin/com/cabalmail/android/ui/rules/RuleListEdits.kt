package com.cabalmail.android.ui.rules

import com.cabalmail.kit.models.FeedRule
import com.cabalmail.kit.models.Rule
import com.cabalmail.kit.models.mintRuleId
import com.cabalmail.kit.rules.FeedRulesValidator
import com.cabalmail.kit.rules.RulesValidator

/**
 * The edits the Rules pane makes to a list of rules: write back an edited
 * rule, add up to the server's cap, duplicate, delete and reorder. The mail
 * list and the feed list are each one of these, so the rules they hold to
 * are written once.
 *
 * Every edit answers the new list, or null when it changes nothing; the
 * view model schedules a save only for a change.
 *
 * A rule this build cannot render ([isEditable] false, which only a feed
 * rule can be) is never rewritten or copied: it can be moved and deleted,
 * and nothing else.
 */
internal class RuleListEdits<T : Any>(
    /** The server's cap on this list; [add] and [duplicate] stop at it. */
    private val maxCount: Int,
    private val id: (T) -> String,
    private val isEditable: (T) -> Boolean,
    /** A copy of the rule under a new id, with " copy" on its name. */
    private val copyOf: (T) -> T,
) {
    fun isFull(rules: List<T>): Boolean = rules.size >= maxCount

    fun update(
        rules: List<T>,
        rule: T,
    ): List<T>? {
        val index = rules.indexOfFirst { id(it) == id(rule) }
        if (index < 0 || !isEditable(rules[index]) || rules[index] == rule) {
            return null
        }
        return rules.toMutableList().apply { set(index, rule) }
    }

    fun add(
        rules: List<T>,
        rule: T,
    ): List<T>? = if (isFull(rules)) null else rules + rule

    /** The list with a copy placed after the rule, and the copy's id. */
    fun duplicate(
        rules: List<T>,
        ruleId: String,
    ): Pair<List<T>, String>? {
        val index = rules.indexOfFirst { id(it) == ruleId }
        if (index < 0 || !isEditable(rules[index]) || isFull(rules)) {
            return null
        }
        val copy = copyOf(rules[index])
        return rules.toMutableList().apply { add(index + 1, copy) } to id(copy)
    }

    fun delete(
        rules: List<T>,
        ruleId: String,
    ): List<T>? = rules.filterNot { id(it) == ruleId }.takeIf { it.size != rules.size }

    /** Moves the rule [delta] places (negative is earlier); past either end nothing moves. */
    fun move(
        rules: List<T>,
        ruleId: String,
        delta: Int,
    ): List<T>? {
        val index = rules.indexOfFirst { id(it) == ruleId }
        val target = index + delta
        if (index < 0 || delta == 0 || target < 0 || target >= rules.size) {
            return null
        }
        return rules.toMutableList().apply { add(target, removeAt(index)) }
    }

    companion object {
        val mail =
            RuleListEdits<Rule>(
                maxCount = RulesValidator.MAX_RULES,
                id = { it.id },
                isEditable = { true },
                copyOf = { it.copy(id = mintRuleId(), name = it.name + " copy") },
            )

        val feed =
            RuleListEdits<FeedRule>(
                maxCount = FeedRulesValidator.MAX_RULES,
                id = { it.id },
                isEditable = { it.isEditable },
                copyOf = { it.copy(id = mintRuleId(), name = it.name + " copy") },
            )
    }
}

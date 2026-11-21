package com.cabalmail.android.ui.rules

import com.cabalmail.kit.models.FeedRule
import com.cabalmail.kit.models.RssSubscription
import com.cabalmail.kit.models.Rule
import com.cabalmail.kit.models.RuleSet
import kotlinx.coroutines.CompletableDeferred

/**
 * A scripted [RulesBackend] that stores what it is sent the way
 * `/set_rules` does: the mail rules are replaced by every save, and the
 * feed rules only by a save that carries a feed list. A save with none
 * leaves the stored list as it was and answers it back.
 */
class FakeRulesBackend : RulesBackend {
    var ruleSet = RuleSet()
    var folders = listOf("INBOX", "Receipts")
    var subscriptions = emptyList<RssSubscription>()
    var subscriptionsError: Exception? = null
    var saveError: Exception? = null

    /** When set, `saveRules` records the save then suspends on this gate
     * — cancellably, like a real HTTP call — mimicking the "server
     * committed, client hung up" case. */
    var saveGate: CompletableDeferred<Unit>? = null

    /** When set, what the server stores for a feed list it is sent, where a
     * real one canonicalizes (re-minted ids, defaults filled in). */
    var canonicalFeedRules: ((List<FeedRule>) -> List<FeedRule>)? = null
    val savedSets = mutableListOf<Pair<List<Rule>, Int>>()

    /** The feed list each save carried, in order; null for a save with none. */
    val savedFeedLists = mutableListOf<List<FeedRule>?>()
    val createdFolders = mutableListOf<String>()
    var subscriptionRequests = 0

    override suspend fun fetchRules(): RuleSet = ruleSet

    override suspend fun saveRules(
        rules: List<Rule>,
        feedRules: List<FeedRule>?,
        expectedVersion: Int,
    ): RuleSet {
        savedSets += rules to expectedVersion
        savedFeedLists += feedRules
        saveGate?.await()
        saveError?.let { throw it }
        val storedFeed =
            if (feedRules == null) ruleSet.feedRules else canonicalFeedRules?.invoke(feedRules) ?: feedRules
        ruleSet = RuleSet(rules = rules, feedRules = storedFeed, version = expectedVersion + 1)
        return ruleSet
    }

    override suspend fun listFolders(): List<String> = folders

    override suspend fun createFolder(name: String) {
        createdFolders += name
        folders = folders + name
    }

    override suspend fun listSubscriptions(): List<RssSubscription> {
        subscriptionRequests += 1
        subscriptionsError?.let { throw it }
        return subscriptions
    }
}

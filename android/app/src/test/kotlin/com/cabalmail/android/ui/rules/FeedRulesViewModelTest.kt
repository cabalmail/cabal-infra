package com.cabalmail.android.ui.rules

import com.cabalmail.kit.CabalmailException
import com.cabalmail.kit.models.FeedRule
import com.cabalmail.kit.models.FeedRuleCondition
import com.cabalmail.kit.models.FeedRuleField
import com.cabalmail.kit.models.RssFeedSummary
import com.cabalmail.kit.models.RssSubscription
import com.cabalmail.kit.models.Rule
import com.cabalmail.kit.models.RuleSet
import com.cabalmail.kit.rules.FeedRulesValidator
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import org.junit.jupiter.api.AfterEach
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNotNull
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.BeforeEach
import org.junit.jupiter.api.Test

/**
 * The feed half of [RulesViewModel] against [FakeRulesBackend], which
 * stores a save the way `/set_rules` does. What matters most here is which
 * saves carry the feed list: the server reads a save without one as "leave
 * the stored list alone", and an edit to the mail rules must stay that
 * request (`docs/mail-rules.md`, "Feed rules", "On the wire").
 */
@OptIn(ExperimentalCoroutinesApi::class)
class FeedRulesViewModelTest {
    private val dispatcher = StandardTestDispatcher()

    @BeforeEach
    fun setUp() {
        Dispatchers.setMain(dispatcher)
    }

    @AfterEach
    fun tearDown() {
        Dispatchers.resetMain()
    }

    private fun mailRule(name: String = "Receipts") = Rule(name = name, flag = true)

    private fun feedRule(
        name: String = "Releases",
        word: String = "release",
    ) = FeedRule(name = name, conditions = listOf(FeedRuleCondition(FeedRuleField.TITLE, word)), flag = true)

    private fun subscription(
        id: String,
        title: String,
    ) = RssSubscription(
        subscriptionId = id,
        feedId = "feed-$id",
        feed = RssFeedSummary(feedId = "feed-$id", title = title),
    )

    /** A backend holding one mail rule and one feed rule at version 3. */
    private fun stocked(): FakeRulesBackend =
        FakeRulesBackend().apply {
            ruleSet = RuleSet(rules = listOf(mailRule()), feedRules = listOf(feedRule()), version = 3)
        }

    @Test
    fun `load takes in both lists under the one version`() =
        runTest(dispatcher) {
            val backend = stocked()

            val model = RulesViewModel(backend)
            advanceUntilIdle()

            val state = model.state.value
            assertEquals(listOf("Receipts"), state.rules?.map { it.name })
            assertEquals(listOf("Releases"), state.feedRules?.map { it.name })
            assertEquals(3, state.version)
            assertTrue(backend.savedSets.isEmpty())
        }

    @Test
    fun `an edit to the mail rules leaves the feed list off the request`() =
        runTest(dispatcher) {
            val backend = stocked()
            val model = RulesViewModel(backend)
            advanceUntilIdle()

            model.update(
                model.state.value.rules!!
                    .first()
                    .copy(name = "Receipts 2026"),
            )
            advanceUntilIdle()

            assertEquals(listOf<List<FeedRule>?>(null), backend.savedFeedLists)
            // ...and the stored feed rule is where it was, here and there.
            assertEquals(listOf("Releases"), backend.ruleSet.feedRules.map { it.name })
            assertEquals(
                listOf("Releases"),
                model.state.value.feedRules
                    ?.map { it.name },
            )
            assertEquals(4, model.state.value.version)
        }

    @Test
    fun `a feed edit sends both lists in one save`() =
        runTest(dispatcher) {
            val backend = stocked()
            val model = RulesViewModel(backend)
            advanceUntilIdle()

            val rule =
                model.state.value.feedRules!!
                    .first()
            model.updateFeedRule(rule.copy(markRead = true))
            advanceUntilIdle()

            assertEquals(1, backend.savedSets.size)
            assertEquals(listOf("Receipts"), backend.savedSets[0].first.map { it.name })
            assertEquals(3, backend.savedSets[0].second)
            assertEquals(listOf(listOf(rule.copy(markRead = true))), backend.savedFeedLists)
            assertEquals(RulesSaveState.Saved, model.state.value.saveState)
        }

    @Test
    fun `once a feed edit is saved, the next mail edit leaves the feed list off again`() =
        runTest(dispatcher) {
            // The server's answer becomes the baseline. Without that the
            // feed list would ride every save after the first feed edit.
            val backend = stocked()
            val model = RulesViewModel(backend)
            advanceUntilIdle()

            model.setFeedRuleEnabled(
                model.state.value.feedRules!!
                    .first()
                    .id,
                false,
            )
            advanceUntilIdle()
            model.update(
                model.state.value.rules!!
                    .first()
                    .copy(name = "Renamed"),
            )
            advanceUntilIdle()

            assertEquals(2, backend.savedFeedLists.size)
            assertNotNull(backend.savedFeedLists[0])
            assertNull(backend.savedFeedLists[1])
        }

    @Test
    fun `deleting the last feed rule sends an empty list, not no list`() =
        runTest(dispatcher) {
            // No list would leave the rule stored; it would come back at
            // the next load.
            val backend = stocked()
            val model = RulesViewModel(backend)
            advanceUntilIdle()

            model.deleteFeedRule(
                model.state.value.feedRules!!
                    .first()
                    .id,
            )
            advanceUntilIdle()

            assertEquals(listOf<List<FeedRule>?>(emptyList()), backend.savedFeedLists)
            assertTrue(backend.ruleSet.feedRules.isEmpty())
            assertEquals(listOf("Receipts"), backend.ruleSet.rules.map { it.name })
        }

    @Test
    fun `a feed edit put back before the save goes sends no feed list`() =
        runTest(dispatcher) {
            val backend = stocked()
            val model = RulesViewModel(backend)
            advanceUntilIdle()

            val rule =
                model.state.value.feedRules!!
                    .first()
            model.updateFeedRule(rule.copy(name = "Changed"))
            model.updateFeedRule(rule)
            advanceUntilIdle()

            assertEquals(listOf<List<FeedRule>?>(null), backend.savedFeedLists)
        }

    @Test
    fun `a feed edit made while a save is out is kept and saved next`() =
        runTest(dispatcher) {
            val backend = stocked()
            val model = RulesViewModel(backend)
            advanceUntilIdle()

            val gate = CompletableDeferred<Unit>()
            backend.saveGate = gate
            val rule =
                model.state.value.feedRules!!
                    .first()
            model.updateFeedRule(rule.copy(name = "First"))
            advanceUntilIdle()
            assertEquals(1, backend.savedSets.size)

            // Typed while the first PUT is parked at the gate.
            model.updateFeedRule(rule.copy(name = "Second"))
            advanceUntilIdle()
            backend.saveGate = null
            gate.complete(Unit)
            advanceUntilIdle()

            // The first answer did not overwrite the edit...
            assertEquals(
                listOf("Second"),
                model.state.value.feedRules
                    ?.map { it.name },
            )
            // ...and it went out next, on the version the first save left.
            assertEquals(2, backend.savedSets.size)
            assertEquals(4, backend.savedSets[1].second)
            assertEquals(listOf("Second"), backend.savedFeedLists[1]?.map { it.name })
            assertEquals(listOf("Second"), backend.ruleSet.feedRules.map { it.name })
        }

    @Test
    fun `the server's copy of the feed list replaces an unedited local one`() =
        runTest(dispatcher) {
            // The server keeps a well-formed id and re-mints any other.
            val backend = stocked()
            backend.canonicalFeedRules = { sent -> sent.map { it.copy(id = "r-00000000000" + sent.indexOf(it)) } }
            val model = RulesViewModel(backend)
            advanceUntilIdle()

            model.addFeedRule(feedRule(name = "Added"))
            advanceUntilIdle()

            assertEquals(
                listOf("r-000000000000", "r-000000000001"),
                model.state.value.feedRules
                    ?.map { it.id },
            )
            // The baseline is what the server stored, so nothing is owed.
            model.update(
                model.state.value.rules!!
                    .first()
                    .copy(name = "Renamed"),
            )
            advanceUntilIdle()
            assertNull(backend.savedFeedLists.last())
        }

    @Test
    fun `an invalid feed rule holds the save of both lists and says why`() =
        runTest(dispatcher) {
            val backend = stocked()
            val model = RulesViewModel(backend)
            advanceUntilIdle()

            val rule =
                model.state.value.feedRules!!
                    .first()
            model.updateFeedRule(rule.copy(conditions = listOf(FeedRuleCondition(FeedRuleField.TITLE, ""))))
            advanceUntilIdle()

            assertTrue(backend.savedSets.isEmpty())
            assertEquals(
                RulesSaveState.Error("Must be 1-500 characters, no control characters."),
                model.state.value.saveState,
            )

            // Fixing the field resumes saving.
            model.updateFeedRule(rule.copy(conditions = listOf(FeedRuleCondition(FeedRuleField.TITLE, "x"))))
            advanceUntilIdle()
            assertEquals(1, backend.savedSets.size)
        }

    @Test
    fun `a stored feed list is not judged when it is not being sent`() =
        runTest(dispatcher) {
            // A list this build would not have written (a newer client's,
            // or one another client left invalid) must not hold a save of
            // the mail rules.
            val backend = FakeRulesBackend()
            backend.ruleSet = RuleSet(rules = listOf(mailRule()), feedRules = listOf(FeedRule(name = "")), version = 1)
            assertTrue(FeedRulesValidator.validate(backend.ruleSet.feedRules).isNotEmpty())
            val model = RulesViewModel(backend)
            advanceUntilIdle()

            model.update(
                model.state.value.rules!!
                    .first()
                    .copy(name = "Renamed"),
            )
            advanceUntilIdle()

            assertEquals(1, backend.savedSets.size)
            assertEquals(listOf<List<FeedRule>?>(null), backend.savedFeedLists)
            assertEquals(RulesSaveState.Saved, model.state.value.saveState)
        }

    @Test
    fun `a blank feed rule is added disabled and saved that way`() =
        runTest(dispatcher) {
            // With no conditions it matches every new item in every feed,
            // and the debounced save puts it on the server at once (#2031).
            val backend = FakeRulesBackend()
            val model = RulesViewModel(backend)
            advanceUntilIdle()

            val id = model.addFeedRule()
            advanceUntilIdle()

            assertNotNull(id)
            val saved = backend.savedFeedLists.single()!!.single()
            assertEquals(id, saved.id)
            assertFalse(saved.enabled)
            assertEquals("New rule", saved.name)
            // It has no action, and that does not hold the save.
            assertFalse(saved.hasAction)
        }

    @Test
    fun `add keeps the enabled flag of a feed rule it is given`() =
        runTest(dispatcher) {
            val backend = FakeRulesBackend()
            val model = RulesViewModel(backend)
            advanceUntilIdle()

            model.addFeedRule(feedRule())
            model.addFeedRule(RuleTemplates.flagMatchingItems())
            advanceUntilIdle()

            assertEquals(
                listOf(true, false),
                model.state.value.feedRules
                    ?.map { it.enabled },
            )
        }

    @Test
    fun `feed list mutations`() =
        runTest(dispatcher) {
            val backend = FakeRulesBackend()
            backend.ruleSet = RuleSet(feedRules = listOf(feedRule("A"), feedRule("B"), feedRule("C")), version = 1)
            val model = RulesViewModel(backend)
            advanceUntilIdle()

            fun names() =
                model.state.value.feedRules!!
                    .map { it.name }

            fun id(name: String) =
                model.state.value.feedRules!!
                    .first { it.name == name }
                    .id

            model.moveFeedRule(id("C"), -2)
            assertEquals(listOf("C", "A", "B"), names())
            model.moveFeedRule(id("C"), -1)
            assertEquals(listOf("C", "A", "B"), names())

            val copyId = model.duplicateFeedRule(id("A"))
            assertEquals(listOf("C", "A", "A copy", "B"), names())
            assertEquals(copyId, id("A copy"))
            assertFalse(copyId == id("A"))

            model.setFeedRuleEnabled(id("B"), false)
            assertFalse(model.feedRule(id("B"))!!.enabled)

            model.deleteFeedRule(id("A copy"))
            assertEquals(listOf("C", "A", "B"), names())
            advanceUntilIdle()

            // One debounced save carried the final list; the mail list was
            // not touched.
            assertEquals(1, backend.savedSets.size)
            assertEquals(listOf("C", "A", "B"), backend.savedFeedLists.single()?.map { it.name })
            assertTrue(
                backend.savedSets
                    .single()
                    .first
                    .isEmpty(),
            )
        }

    @Test
    fun `adding a feed rule stops at the server cap and leaves the mail list its own`() =
        runTest(dispatcher) {
            val backend = FakeRulesBackend()
            backend.ruleSet = RuleSet(feedRules = List(100) { feedRule("R$it") }, version = 1)
            val model = RulesViewModel(backend)
            advanceUntilIdle()

            assertNull(model.addFeedRule())
            assertNull(
                model.duplicateFeedRule(
                    model.state.value.feedRules!!
                        .first()
                        .id,
                ),
            )
            assertEquals(
                100,
                model.state.value.feedRules
                    ?.size,
            )
            // The cap is each list's own.
            assertNotNull(model.add())
        }

    @Test
    fun `a rule this build cannot render is moved and deleted, never rewritten or copied`() =
        runTest(dispatcher) {
            val opaque =
                FeedRule(
                    name = "Later",
                    conditions = listOf(FeedRuleCondition(FeedRuleField("category"), "news")),
                    flag = true,
                )
            val backend = FakeRulesBackend()
            backend.ruleSet = RuleSet(feedRules = listOf(feedRule("A"), opaque), version = 1)
            val model = RulesViewModel(backend)
            advanceUntilIdle()

            model.updateFeedRule(opaque.copy(name = "Rewritten"))
            model.setFeedRuleEnabled(opaque.id, false)
            assertNull(model.duplicateFeedRule(opaque.id))
            advanceUntilIdle()
            assertTrue(backend.savedSets.isEmpty())
            assertEquals(opaque, model.feedRule(opaque.id))

            // Moved, it is saved back as it was decoded.
            model.moveFeedRule(opaque.id, -1)
            advanceUntilIdle()
            assertEquals(listOf(opaque, model.state.value.feedRules!![1]), backend.savedFeedLists.single())

            model.deleteFeedRule(opaque.id)
            advanceUntilIdle()
            assertEquals(listOf("A"), backend.ruleSet.feedRules.map { it.name })
        }

    @Test
    fun `a conflict on a feed save flips the flag and reload takes both of the winner's lists`() =
        runTest(dispatcher) {
            val backend = stocked()
            val model = RulesViewModel(backend)
            advanceUntilIdle()

            backend.saveError = CabalmailException.RuleSetConflict()
            model.updateFeedRule(
                model.state.value.feedRules!!
                    .first()
                    .copy(name = "Mine"),
            )
            advanceUntilIdle()
            assertTrue(model.state.value.conflict)

            backend.saveError = null
            backend.ruleSet =
                RuleSet(rules = listOf(mailRule("Theirs")), feedRules = listOf(feedRule("Theirs too")), version = 9)
            model.load()
            advanceUntilIdle()

            val state = model.state.value
            assertFalse(state.conflict)
            assertEquals(listOf("Theirs"), state.rules?.map { it.name })
            assertEquals(listOf("Theirs too"), state.feedRules?.map { it.name })
            assertEquals(9, state.version)
            // The reload is the new baseline: a mail edit owes no feed list.
            model.update(state.rules!!.first().copy(name = "Renamed"))
            advanceUntilIdle()
            assertNull(backend.savedFeedLists.last())
        }

    @Test
    fun `the subscriptions load by title for the Feed picker`() =
        runTest(dispatcher) {
            val backend = stocked()
            backend.subscriptions = listOf(subscription("s2", "zebra"), subscription("s1", "Apple"))

            val model = RulesViewModel(backend)
            advanceUntilIdle()

            assertEquals(
                listOf("Apple", "zebra"),
                model.state.value.subscriptions
                    ?.map { it.displayTitle },
            )
            assertEquals("zebra", model.state.value.subscriptionTitle("s2"))
            assertNull(model.state.value.subscriptionTitle("gone"))
            assertNull(model.state.value.subscriptionTitle(null))
        }

    @Test
    fun `a later visit to the pane asks for the subscriptions again`() =
        runTest(dispatcher) {
            // The view model outlives a visit: a feed subscribed to in the
            // Feeds tab since the load must reach the picker, and one
            // unsubscribed from must leave it.
            val backend = stocked()
            backend.subscriptions = listOf(subscription("s1", "Apple"))
            val model = RulesViewModel(backend)
            advanceUntilIdle()
            assertEquals(1, backend.subscriptionRequests)

            backend.subscriptions = listOf(subscription("s3", "New feed"))
            model.refreshSubscriptions()
            advanceUntilIdle()

            assertEquals(
                listOf("New feed"),
                model.state.value.subscriptions
                    ?.map { it.displayTitle },
            )
            // The rules were not fetched again, and nothing was saved.
            assertEquals(
                listOf("Releases"),
                model.state.value.feedRules
                    ?.map { it.name },
            )
            assertTrue(backend.savedSets.isEmpty())
        }

    @Test
    fun `the pane's first visit does not ask twice`() =
        runTest(dispatcher) {
            // The load asks as its last step; the visit that started it
            // need not ask beside it.
            val backend = stocked()
            val model = RulesViewModel(backend)
            model.refreshSubscriptions()
            advanceUntilIdle()

            assertEquals(1, backend.subscriptionRequests)
        }

    @Test
    fun `a refresh that fails keeps the list it had`() =
        runTest(dispatcher) {
            val backend = stocked()
            backend.subscriptions = listOf(subscription("s1", "Apple"))
            val model = RulesViewModel(backend)
            advanceUntilIdle()

            backend.subscriptionsError = IllegalStateException("offline")
            model.refreshSubscriptions()
            advanceUntilIdle()

            assertEquals(
                listOf("Apple"),
                model.state.value.subscriptions
                    ?.map { it.displayTitle },
            )
        }

    @Test
    fun `subscriptions that fail to load stay unknown, and the rules still load`() =
        runTest(dispatcher) {
            val backend = stocked()
            backend.subscriptionsError = IllegalStateException("offline")

            val model = RulesViewModel(backend)
            advanceUntilIdle()

            // Null, not empty: an empty list would call every rule's feed
            // unsubscribed.
            assertNull(model.state.value.subscriptions)
            assertEquals(
                listOf("Releases"),
                model.state.value.feedRules
                    ?.map { it.name },
            )
            assertNull(model.state.value.loadError)
        }
}

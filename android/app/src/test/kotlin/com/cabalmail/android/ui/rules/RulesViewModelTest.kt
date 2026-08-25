package com.cabalmail.android.ui.rules

import com.cabalmail.kit.CabalmailException
import com.cabalmail.kit.models.Rule
import com.cabalmail.kit.models.RuleAction
import com.cabalmail.kit.models.RuleCondition
import com.cabalmail.kit.models.RuleField
import com.cabalmail.kit.models.RuleSet
import com.cabalmail.kit.rules.RulesValidator
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
import org.junit.jupiter.api.Assertions.assertNotEquals
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.BeforeEach
import org.junit.jupiter.api.Test

/**
 * [RulesViewModel] behavior against a scripted [RulesBackend]: load,
 * debounced whole-set saves, the validation gate, optimistic-concurrency
 * conflict handling, and the list mutations. The virtual-time dispatcher
 * drives `viewModelScope`, so the 300ms debounce runs instantly.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class RulesViewModelTest {
    private val dispatcher = StandardTestDispatcher()

    @BeforeEach
    fun setUp() {
        Dispatchers.setMain(dispatcher)
    }

    @AfterEach
    fun tearDown() {
        Dispatchers.resetMain()
    }

    private class FakeBackend : RulesBackend {
        var ruleSet = RuleSet()
        var folders = listOf("INBOX", "Receipts")
        var saveError: Exception? = null

        /** When set, `saveRules` records the save then suspends on this gate
         * — cancellably, like a real HTTP call — mimicking the "server
         * committed, client hung up" case. */
        var saveGate: CompletableDeferred<Unit>? = null
        val savedSets = mutableListOf<Pair<List<Rule>, Int>>()
        val createdFolders = mutableListOf<String>()

        override suspend fun fetchRules(): RuleSet = ruleSet

        override suspend fun saveRules(
            rules: List<Rule>,
            expectedVersion: Int,
        ): RuleSet {
            savedSets += rules to expectedVersion
            saveGate?.await()
            saveError?.let { throw it }
            return RuleSet(rules = rules, version = expectedVersion + 1)
        }

        override suspend fun listFolders(): List<String> = folders

        override suspend fun createFolder(name: String) {
            createdFolders += name
            folders = folders + name
        }
    }

    private fun sampleRule(name: String = "Receipts"): Rule =
        Rule(
            name = name,
            conditions = listOf(RuleCondition(RuleField.SUBJECT, "invoice")),
            action = RuleAction.MOVE,
            moveFolder = "Receipts",
        )

    @Test
    fun `load populates rules version and folders`() =
        runTest(dispatcher) {
            val backend = FakeBackend()
            backend.ruleSet = RuleSet(rules = listOf(sampleRule()), version = 5)

            val model = RulesViewModel(backend)
            advanceUntilIdle()

            val state = model.state.value
            assertEquals(listOf("Receipts"), state.rules?.map { it.name })
            assertEquals(5, state.version)
            assertFalse(state.loading)
            assertEquals(listOf("INBOX", "Receipts"), state.folders)
        }

    @Test
    fun `update schedules a debounced whole-set save`() =
        runTest(dispatcher) {
            val backend = FakeBackend()
            backend.ruleSet = RuleSet(rules = listOf(sampleRule()), version = 5)
            val model = RulesViewModel(backend)
            advanceUntilIdle()

            model.update(
                model.state.value.rules!!
                    .first()
                    .copy(name = "Receipts 2026"),
            )
            advanceUntilIdle()

            assertEquals(1, backend.savedSets.size)
            assertEquals(listOf("Receipts 2026"), backend.savedSets[0].first.map { it.name })
            assertEquals(5, backend.savedSets[0].second)
            // The response version becomes the next expectedVersion.
            assertEquals(6, model.state.value.version)
            assertEquals(RulesSaveState.Saved, model.state.value.saveState)
        }

    @Test
    fun `rapid mutations coalesce into one save carrying the final order`() =
        runTest(dispatcher) {
            val backend = FakeBackend()
            backend.ruleSet = RuleSet(rules = listOf(sampleRule()), version = 1)
            val model = RulesViewModel(backend)
            advanceUntilIdle()

            model.add(sampleRule(name = "A"))
            model.add(sampleRule(name = "B"))
            model.state.value.rules!!
                .last()
                .let { model.move(it.id, -2) }
            advanceUntilIdle()

            assertEquals(1, backend.savedSets.size)
            assertEquals(listOf("B", "Receipts", "A"), backend.savedSets[0].first.map { it.name })
        }

    @Test
    fun `an invalid set holds the put and surfaces the issue`() =
        runTest(dispatcher) {
            val backend = FakeBackend()
            val model = RulesViewModel(backend)
            advanceUntilIdle()

            model.add(sampleRule(name = ""))
            advanceUntilIdle()

            assertTrue(backend.savedSets.isEmpty())
            assertTrue(model.state.value.saveState is RulesSaveState.Error)
        }

    @Test
    fun `a conflict flips the flag and reload adopts the winner`() =
        runTest(dispatcher) {
            val backend = FakeBackend()
            backend.ruleSet = RuleSet(rules = listOf(sampleRule()), version = 2)
            val model = RulesViewModel(backend)
            advanceUntilIdle()

            backend.saveError = CabalmailException.RuleSetConflict()
            model.update(
                model.state.value.rules!!
                    .first()
                    .copy(name = "Mine"),
            )
            advanceUntilIdle()
            assertTrue(model.state.value.conflict)

            backend.saveError = null
            backend.ruleSet = RuleSet(rules = listOf(sampleRule(name = "Theirs")), version = 9)
            model.load()
            advanceUntilIdle()

            val state = model.state.value
            assertFalse(state.conflict)
            assertEquals(listOf("Theirs"), state.rules?.map { it.name })
            assertEquals(9, state.version)
        }

    @Test
    fun `a mutation during an in-flight save does not cancel the put`() =
        runTest(dispatcher) {
            // UAT regression: a keystroke landing while a PUT is in flight
            // must not cancel that request. The server commits a PUT whether
            // or not the client hangs up, so an aborted request left
            // `version` stale and the next save's 409 masqueraded as another
            // device's edit ("only the A in Amazon was saved").
            val backend = FakeBackend()
            backend.ruleSet = RuleSet(rules = listOf(sampleRule()), version = 1)
            val model = RulesViewModel(backend)
            advanceUntilIdle()

            val gate = CompletableDeferred<Unit>()
            backend.saveGate = gate
            model.update(
                model.state.value.rules!!
                    .first()
                    .copy(name = "A"),
            )
            advanceUntilIdle()
            assertEquals(1, backend.savedSets.size)

            // Keystroke while PUT 1 is parked at the gate: before the fix
            // this cancelled the save's job, aborting the request.
            model.update(
                model.state.value.rules!!
                    .first()
                    .copy(name = "Amazon"),
            )
            advanceUntilIdle()
            backend.saveGate = null
            gate.complete(Unit)
            advanceUntilIdle()

            // The follow-up save carries PUT 1's response version, not a
            // stale one, and no conflict is reported.
            assertEquals(2, backend.savedSets.size)
            assertEquals(2, backend.savedSets[1].second)
            assertEquals(listOf("Amazon"), backend.savedSets[1].first.map { it.name })
            assertFalse(model.state.value.conflict)
            assertEquals(3, model.state.value.version)
        }

    @Test
    fun `list mutations`() =
        runTest(dispatcher) {
            val backend = FakeBackend()
            backend.ruleSet = RuleSet(rules = listOf(sampleRule()), version = 1)
            val model = RulesViewModel(backend)
            advanceUntilIdle()

            val newId = model.add()
            assertEquals(
                2,
                model.state.value.rules
                    ?.size,
            )
            assertEquals(
                newId,
                model.state.value.rules
                    ?.last()
                    ?.id,
            )

            val copyId =
                model.duplicate(
                    model.state.value.rules!![0]
                        .id,
                )
            val rules = model.state.value.rules!!
            assertEquals(3, rules.size)
            assertEquals(copyId, rules[1].id)
            assertEquals("Receipts copy", rules[1].name)
            assertNotEquals(rules[0].id, rules[1].id)

            model.setEnabled(rules[0].id, false)
            assertFalse(
                model.state.value.rules!![0]
                    .enabled,
            )

            model.delete(rules[0].id)
            assertEquals(
                2,
                model.state.value.rules
                    ?.size,
            )
        }

    @Test
    fun `add refuses beyond the server cap`() =
        runTest(dispatcher) {
            val backend = FakeBackend()
            backend.ruleSet =
                RuleSet(rules = List(RulesValidator.MAX_RULES) { Rule(name = "r$it") }, version = 1)
            val model = RulesViewModel(backend)
            advanceUntilIdle()

            assertNull(model.add())
            assertEquals(
                RulesValidator.MAX_RULES,
                model.state.value.rules
                    ?.size,
            )
        }

    @Test
    fun `create archive folder refreshes the folder list`() =
        runTest(dispatcher) {
            val backend = FakeBackend()
            val model = RulesViewModel(backend)
            advanceUntilIdle()
            assertFalse(model.state.value.hasArchiveFolder)

            model.createArchiveFolder()
            advanceUntilIdle()

            assertEquals(listOf("Archive"), backend.createdFolders)
            assertTrue(model.state.value.hasArchiveFolder)
        }
}

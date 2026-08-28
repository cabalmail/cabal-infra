package com.cabalmail.android.ui.rules

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import com.cabalmail.android.AppContainer
import com.cabalmail.android.userMessage
import com.cabalmail.kit.CabalmailException
import com.cabalmail.kit.models.Rule
import com.cabalmail.kit.models.RuleSet
import com.cabalmail.kit.models.mintRuleId
import com.cabalmail.kit.models.normalizeLegacyContinue
import com.cabalmail.kit.rules.RulesValidator
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

/**
 * The slice of the client the rules editor needs, narrowed so tests can
 * fake four calls instead of the whole [com.cabalmail.kit.api.ApiClient]
 * (the same shape as the Apple client's `RulesBackend`).
 */
interface RulesBackend {
    suspend fun fetchRules(): RuleSet

    suspend fun saveRules(
        rules: List<Rule>,
        expectedVersion: Int,
    ): RuleSet

    /** Folder display paths for the destination pickers. */
    suspend fun listFolders(): List<String>

    suspend fun createFolder(name: String)
}

private class LiveRulesBackend(
    private val container: AppContainer,
) : RulesBackend {
    override suspend fun fetchRules(): RuleSet = container.requireApi().getRules()

    override suspend fun saveRules(
        rules: List<Rule>,
        expectedVersion: Int,
    ): RuleSet = container.requireApi().setRules(rules, expectedVersion)

    override suspend fun listFolders(): List<String> = container.requireApi().listFolders().folders

    override suspend fun createFolder(name: String) {
        container.requireApi().newFolder(name)
    }
}

/** The auto-save indicator's state machine (idle / saving / saved / error). */
sealed interface RulesSaveState {
    data object Idle : RulesSaveState

    data object Saving : RulesSaveState

    data object Saved : RulesSaveState

    data class Error(
        val message: String,
    ) : RulesSaveState
}

data class RulesUiState(
    /** Ordered rule list; null until the first load lands. */
    val rules: List<Rule>? = null,
    val version: Int = 0,
    val loading: Boolean = true,
    val loadError: String? = null,
    val saveState: RulesSaveState = RulesSaveState.Idle,
    /** Another device saved first (409) — drives the reload dialog. */
    val conflict: Boolean = false,
    /** The user's existing folders; null until loaded (pickers offer these only). */
    val folders: List<String>? = null,
) {
    val hasArchiveFolder: Boolean get() = folders.orEmpty().contains("Archive")
}

/**
 * State for the mail-rules editor (`docs/1.x/user-mail-rules-plan.md`,
 * Phase 4b): the ordered rule list, the optimistic-concurrency version, and
 * the debounced whole-set auto-save.
 *
 * Every mutation splices the local list and schedules one debounced PUT of
 * the entire set — list order is precedence server-side, so there is no
 * per-rule save. A set the validator rejects holds the PUT and surfaces
 * the first issue instead (the server would 400 it). A save that loses the
 * version race flips `conflict`; the dialog's only affordance is Reload,
 * matching the other clients (no merge UI in v1).
 */
class RulesViewModel(
    private val backend: RulesBackend,
    private val saveDebounceMillis: Long = 300,
) : ViewModel() {
    private val mutableState = MutableStateFlow(RulesUiState())
    val state: StateFlow<RulesUiState> = mutableState.asStateFlow()

    private var debounceJob: Job? = null
    private var saveInFlight = false
    private var pendingSave = false

    init {
        load()
    }

    /** Fetches the rule set (replacing all local state — also the conflict
     * dialog's Reload path) and refreshes the folder list best-effort. */
    fun load() {
        viewModelScope.launch {
            mutableState.update { it.copy(loading = true, loadError = null, conflict = false) }
            try {
                val ruleSet = backend.fetchRules()
                mutableState.update {
                    it.copy(
                        // Legacy move/archive + continue renders and saves as
                        // the Copy it compiles to (truthful Continue,
                        // decision 2). One-way; the normalized form persists
                        // on the next edit's save.
                        rules = ruleSet.rules.map { rule -> rule.normalizeLegacyContinue() },
                        version = ruleSet.version,
                        loading = false,
                        saveState = RulesSaveState.Idle,
                    )
                }
                pendingSave = false
            } catch (exception: Exception) {
                mutableState.update {
                    it.copy(loading = false, loadError = userMessage(exception, "Could not load rules"))
                }
            }
            refreshFolders()
        }
    }

    private suspend fun refreshFolders() {
        runCatching { backend.listFolders() }
            .onSuccess { folders -> mutableState.update { it.copy(folders = folders) } }
    }

    /** The one sanctioned folder creation: the user explicitly asked for an
     * Archive folder from the Archive action's inline prompt. */
    fun createArchiveFolder() {
        viewModelScope.launch {
            runCatching { backend.createFolder("Archive") }
            refreshFolders()
        }
    }

    // ------------------------------------------------------------ mutations

    fun rule(id: String): Rule? = mutableState.value.rules?.firstOrNull { it.id == id }

    fun update(rule: Rule) {
        mutate { rules ->
            val index = rules.indexOfFirst { it.id == rule.id }
            if (index < 0 || rules[index] == rule) null else rules.toMutableList().apply { set(index, rule) }
        }
    }

    /** Appends and returns the new rule's id (for navigation), or null at
     * the server's rule-count cap. */
    fun add(rule: Rule = Rule(name = "New rule")): String? {
        var added: String? = null
        mutate { rules ->
            if (rules.size >= RulesValidator.MAX_RULES) {
                null
            } else {
                added = rule.id
                rules + rule
            }
        }
        return added
    }

    fun duplicate(id: String): String? {
        var copyId: String? = null
        mutate { rules ->
            val index = rules.indexOfFirst { it.id == id }
            if (index < 0 || rules.size >= RulesValidator.MAX_RULES) {
                null
            } else {
                val copy = rules[index].copy(id = mintRuleId(), name = rules[index].name + " copy")
                copyId = copy.id
                rules.toMutableList().apply { add(index + 1, copy) }
            }
        }
        return copyId
    }

    fun delete(id: String) {
        mutate { rules -> rules.filterNot { it.id == id }.takeIf { it.size != rules.size } }
    }

    /** Moves the rule [delta] positions (negative = earlier = higher precedence). */
    fun move(
        id: String,
        delta: Int,
    ) {
        mutate { rules ->
            val index = rules.indexOfFirst { it.id == id }
            val target = index + delta
            if (index < 0 || target < 0 || target >= rules.size) {
                null
            } else {
                rules.toMutableList().apply { add(target, removeAt(index)) }
            }
        }
    }

    fun setEnabled(
        id: String,
        enabled: Boolean,
    ) {
        rule(id)?.let { update(it.copy(enabled = enabled)) }
    }

    /** Applies [change] (null = no-op) and schedules the debounced save. */
    private fun mutate(change: (List<Rule>) -> List<Rule>?) {
        val current = mutableState.value.rules ?: return
        val next = change(current) ?: return
        mutableState.update { it.copy(rules = next) }
        scheduleSave()
    }

    // -------------------------------------------------------------- saving

    /** Immediate retry for the error state's Retry affordance. */
    fun retrySave() {
        debounceJob?.cancel()
        viewModelScope.launch { performSave() }
    }

    private fun scheduleSave() {
        debounceJob?.cancel()
        debounceJob =
            viewModelScope.launch {
                delay(saveDebounceMillis)
                // The PUT runs as its own job (a sibling on viewModelScope,
                // not a child of the debounce): cancelling the debounce (the
                // next keystroke) must never abort an in-flight request. The
                // server commits a PUT whether or not the client hangs up,
                // so an aborted request leaves `version` stale and the next
                // save misreads its 409 as another device's edit.
                viewModelScope.launch { performSave() }
            }
    }

    private suspend fun performSave() {
        if (saveInFlight) {
            pendingSave = true
            return
        }
        val snapshot = mutableState.value.rules ?: return
        // A set the validator rejects is a set the server 400s (or strips);
        // hold the PUT and surface the first problem instead. The next
        // mutation reschedules, so fixing the field resumes saving.
        RulesValidator.validate(snapshot).firstOrNull()?.let { issue ->
            mutableState.update { it.copy(saveState = RulesSaveState.Error(issue.message)) }
            return
        }
        saveInFlight = true
        mutableState.update { it.copy(saveState = RulesSaveState.Saving) }
        try {
            val saved = backend.saveRules(snapshot, mutableState.value.version)
            mutableState.update {
                it.copy(
                    version = saved.version,
                    // Adopt the server-canonical set (ids it re-minted,
                    // forwards it stripped) only if nothing changed locally
                    // mid-flight; edits during the PUT have already
                    // scheduled their own save.
                    rules =
                        if (it.rules == snapshot) {
                            saved.rules.map { rule -> rule.normalizeLegacyContinue() }
                        } else {
                            it.rules
                        },
                    saveState = RulesSaveState.Saved,
                )
            }
        } catch (exception: CabalmailException.RuleSetConflict) {
            mutableState.update { it.copy(conflict = true, saveState = RulesSaveState.Idle) }
        } catch (exception: Exception) {
            mutableState.update {
                it.copy(saveState = RulesSaveState.Error(userMessage(exception, "Could not save rules")))
            }
        }
        saveInFlight = false
        if (pendingSave) {
            pendingSave = false
            scheduleSave()
        }
    }

    companion object {
        fun factory(container: AppContainer): ViewModelProvider.Factory =
            viewModelFactory {
                initializer { RulesViewModel(LiveRulesBackend(container)) }
            }
    }
}

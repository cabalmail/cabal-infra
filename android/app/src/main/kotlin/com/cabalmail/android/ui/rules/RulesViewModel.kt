package com.cabalmail.android.ui.rules

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import com.cabalmail.android.AppContainer
import com.cabalmail.android.userMessage
import com.cabalmail.kit.CabalmailException
import com.cabalmail.kit.models.FeedRule
import com.cabalmail.kit.models.RssSubscription
import com.cabalmail.kit.models.Rule
import com.cabalmail.kit.models.RuleSet
import com.cabalmail.kit.models.normalizeLegacyContinue
import com.cabalmail.kit.rules.FeedRulesValidator
import com.cabalmail.kit.rules.RulesValidator
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

/**
 * The slice of the client the rules editor needs, narrowed so tests can
 * fake five calls instead of the whole [com.cabalmail.kit.api.ApiClient]
 * (the same shape as the Apple client's `RulesBackend`).
 */
interface RulesBackend {
    suspend fun fetchRules(): RuleSet

    /**
     * Saves the mail rules and, when [feedRules] is not null, the feed
     * rules, under the one version. Null leaves the stored feed list alone
     * ([com.cabalmail.kit.api.ApiClient.setRules]).
     */
    suspend fun saveRules(
        rules: List<Rule>,
        feedRules: List<FeedRule>?,
        expectedVersion: Int,
    ): RuleSet

    /** Folder display paths for the destination pickers. */
    suspend fun listFolders(): List<String>

    suspend fun createFolder(name: String)

    /** The user's feed subscriptions, for a feed rule's Feed picker. */
    suspend fun listSubscriptions(): List<RssSubscription>
}

private class LiveRulesBackend(
    private val container: AppContainer,
) : RulesBackend {
    override suspend fun fetchRules(): RuleSet = container.requireApi().getRules()

    override suspend fun saveRules(
        rules: List<Rule>,
        feedRules: List<FeedRule>?,
        expectedVersion: Int,
    ): RuleSet = container.requireApi().setRules(rules, expectedVersion, feedRules)

    override suspend fun listFolders(): List<String> = container.requireApi().listFolders().folders

    override suspend fun createFolder(name: String) {
        container.requireApi().newFolder(name)
    }

    /**
     * Asked of the server, as the folder list is, and read without touching
     * the feed database: replacing the stored catalog is the Feeds screen's
     * to do, since it also has to drop the web profiles of feeds that have
     * gone. Offline, the feeds this device last synced stand in.
     */
    override suspend fun listSubscriptions(): List<RssSubscription> =
        try {
            container.requireApi().listSubscriptions().subscriptions
        } catch (exception: CancellationException) {
            throw exception
        } catch (exception: Exception) {
            container.rssStore.subscriptions().ifEmpty { throw exception }
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
    /**
     * The feed rules, loaded and saved with [rules] under the one
     * [version]; null until the first load lands. Their order is only how
     * they are shown: every matching rule applies.
     */
    val feedRules: List<FeedRule>? = null,
    val version: Int = 0,
    val loading: Boolean = true,
    val loadError: String? = null,
    val saveState: RulesSaveState = RulesSaveState.Idle,
    /** Another device saved first (409) — drives the reload dialog. */
    val conflict: Boolean = false,
    /** The user's existing folders; null until loaded (pickers offer these only). */
    val folders: List<String>? = null,
    /**
     * The user's feed subscriptions by title, for a feed rule's Feed picker
     * and its row's summary. Null until they have loaded: a rule's feed is
     * then shown without its name, and is not called unsubscribed.
     */
    val subscriptions: List<RssSubscription>? = null,
) {
    val hasArchiveFolder: Boolean get() = folders.orEmpty().contains("Archive")

    /** The title of the subscription a feed rule is limited to, where this device knows it. */
    fun subscriptionTitle(id: String?): String? = subscriptions?.firstOrNull { it.subscriptionId == id }?.displayTitle
}

/**
 * State for the rules editor (`docs/1.x/user-mail-rules-plan.md`, Phase 4b,
 * and `docs/1.x/cross-media-ux-plan.md`, Phase 4): the ordered mail rule
 * list, the feed rule list beside it, the optimistic-concurrency version
 * they share, and the debounced whole-set auto-save.
 *
 * Every mutation splices a local list and schedules one debounced PUT of
 * the entire set — list order is precedence server-side, so there is no
 * per-rule save. A set the validator rejects holds the PUT and surfaces
 * the first issue instead (the server would 400 it). A save that loses the
 * version race flips `conflict`; the dialog's only affordance is Reload,
 * matching the other clients (no merge UI in v1).
 *
 * The two lists are one row on the server, so one request saves both. The
 * feed list rides that request only when it differs from what the server
 * last answered ([serverFeedRules]). `/set_rules` reads a request with no
 * `feedRules` key as "leave the stored list alone", which is what every
 * build from before feed rules sends; sending the same for an edit to the
 * mail rules means such an edit can never rewrite a feed rule, including
 * one this build decoded without everything a newer build wrote into it.
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

    /** The feed rules as the server last answered them: what the row holds. */
    private var serverFeedRules: List<FeedRule> = emptyList()

    init {
        load()
    }

    /** Fetches the rule set (replacing all local state — also the conflict
     * dialog's Reload path) and refreshes the folder list and the feed
     * subscriptions best-effort. */
    fun load() {
        viewModelScope.launch {
            mutableState.update { it.copy(loading = true, loadError = null, conflict = false) }
            try {
                val ruleSet = backend.fetchRules()
                serverFeedRules = ruleSet.feedRules
                mutableState.update {
                    it.copy(
                        // Legacy move/archive + continue renders and saves as
                        // the Copy it compiles to (truthful Continue,
                        // decision 2). One-way; the normalized form persists
                        // on the next edit's save.
                        rules = ruleSet.rules.map { rule -> rule.normalizeLegacyContinue() },
                        feedRules = ruleSet.feedRules,
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
            loadSubscriptions()
        }
    }

    private suspend fun refreshFolders() {
        runCatching { backend.listFolders() }
            .onSuccess { folders -> mutableState.update { it.copy(folders = folders) } }
    }

    /**
     * Asks again for the feeds the Feed picker offers. Called when the
     * Rules pane or a feed rule's editor comes on screen: this view model
     * outlives a visit to the pane (it belongs to Settings, which keeps its
     * state while another tab is in front), so a feed subscribed to since
     * the load would otherwise be missing from the picker, and one
     * unsubscribed from would still be offered, until the app restarted.
     *
     * Nothing to do while a load is running: it asks as its last step.
     */
    fun refreshSubscriptions() {
        if (mutableState.value.loading) {
            return
        }
        viewModelScope.launch { loadSubscriptions() }
    }

    /** A failure leaves what was there: the pickers keep the last list, or
     * none, and a rule's feed is then shown without its name. */
    private suspend fun loadSubscriptions() {
        runCatching { backend.listSubscriptions() }
            .onSuccess { subscriptions ->
                val byTitle = subscriptions.sortedBy { it.displayTitle.lowercase() }
                mutableState.update { it.copy(subscriptions = byTitle) }
            }
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
        mutate { rules -> RuleListEdits.mail.update(rules, rule) }
    }

    /** Appends and returns the new rule's id (for navigation), or null at
     * the server's rule-count cap.
     *
     * A blank rule arrives disabled, as every template does: it has no
     * conditions, so it matches every message, and the debounced save puts
     * it on the server within moments. Enabled, it is a live every-message
     * rule the user never switched on (#2031). The wire default stays
     * `true` in [Rule] -- a rule the server sends without the key is
     * enabled. */
    fun add(rule: Rule = Rule(name = "New rule", enabled = false)): String? {
        var added: String? = null
        mutate { rules -> RuleListEdits.mail.add(rules, rule)?.also { added = rule.id } }
        return added
    }

    fun duplicate(id: String): String? {
        var copyId: String? = null
        mutate { rules ->
            RuleListEdits.mail
                .duplicate(rules, id)
                ?.also { copyId = it.second }
                ?.first
        }
        return copyId
    }

    fun delete(id: String) {
        mutate { rules -> RuleListEdits.mail.delete(rules, id) }
    }

    /** Moves the rule [delta] positions (negative = earlier = higher precedence). */
    fun move(
        id: String,
        delta: Int,
    ) {
        mutate { rules -> RuleListEdits.mail.move(rules, id, delta) }
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

    // ---------------------------------------------------- feed rule mutations

    fun feedRule(id: String): FeedRule? = mutableState.value.feedRules?.firstOrNull { it.id == id }

    /** Writes an edited feed rule back. Refused for a rule this build
     * cannot render ([FeedRule.isEditable]), which is saved as it was. */
    fun updateFeedRule(rule: FeedRule) {
        mutateFeed { rules -> RuleListEdits.feed.update(rules, rule) }
    }

    /** Appends and returns the new feed rule's id (for navigation), or null
     * at the server's cap.
     *
     * A blank feed rule arrives disabled, as a blank mail rule does
     * (#2031): with no conditions it matches every new item in every feed,
     * and it is saved within a debounce of being added. */
    fun addFeedRule(rule: FeedRule = FeedRule(name = "New rule", enabled = false)): String? {
        var added: String? = null
        mutateFeed { rules -> RuleListEdits.feed.add(rules, rule)?.also { added = rule.id } }
        return added
    }

    fun duplicateFeedRule(id: String): String? {
        var copyId: String? = null
        mutateFeed { rules ->
            RuleListEdits.feed
                .duplicate(rules, id)
                ?.also { copyId = it.second }
                ?.first
        }
        return copyId
    }

    fun deleteFeedRule(id: String) {
        mutateFeed { rules -> RuleListEdits.feed.delete(rules, id) }
    }

    /** Order means nothing to the fetcher (every matching rule applies); it
     * is how the list is shown, and it is stored, so a reorder saves. */
    fun moveFeedRule(
        id: String,
        delta: Int,
    ) {
        mutateFeed { rules -> RuleListEdits.feed.move(rules, id, delta) }
    }

    fun setFeedRuleEnabled(
        id: String,
        enabled: Boolean,
    ) {
        feedRule(id)?.let { updateFeedRule(it.copy(enabled = enabled)) }
    }

    private fun mutateFeed(change: (List<FeedRule>) -> List<FeedRule>?) {
        val current = mutableState.value.feedRules ?: return
        val next = change(current) ?: return
        mutableState.update { it.copy(feedRules = next) }
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
        val feedSnapshot = mutableState.value.feedRules ?: return
        // The feed list goes only when it differs from what the server
        // holds (see the class comment); unsent, it is not judged either,
        // so a stored list this build would not have written cannot hold a
        // save of the mail rules.
        val feedToSend = feedSnapshot.takeIf { it != serverFeedRules }
        // A set the validator rejects is a set the server 400s (or strips);
        // hold the PUT and surface the first problem instead. The next
        // mutation reschedules, so fixing the field resumes saving.
        val issue =
            RulesValidator.validate(snapshot).firstOrNull()
                ?: feedToSend?.let { FeedRulesValidator.validate(it).firstOrNull() }
        if (issue != null) {
            mutableState.update { it.copy(saveState = RulesSaveState.Error(issue.message)) }
            return
        }
        saveInFlight = true
        mutableState.update { it.copy(saveState = RulesSaveState.Saving) }
        try {
            val saved = backend.saveRules(snapshot, feedToSend, mutableState.value.version)
            // What the row now holds, whether or not the list was sent.
            serverFeedRules = saved.feedRules
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
                    // The same guard for the feed list: an edit made during
                    // the PUT stays, unsaved against the new baseline, and
                    // has scheduled a save of its own.
                    feedRules = if (it.feedRules == feedSnapshot) saved.feedRules else it.feedRules,
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

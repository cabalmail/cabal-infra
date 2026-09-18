package com.cabalmail.android.ui.mail

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import com.cabalmail.android.AppContainer
import com.cabalmail.android.userMessage
import com.cabalmail.kit.api.ApiClient
import com.cabalmail.kit.models.FolderStatus
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

data class FoldersUiState(
    /** Null until the first load; server order (INBOX pinned first). */
    val folders: List<String>? = null,
    /** Paths the user has subscribed to (`sub_folders` on the wire). */
    val subscribed: Set<String> = emptySet(),
    val statuses: Map<String, FolderStatus> = emptyMap(),
    val refreshing: Boolean = false,
    val error: String? = null,
)

/** Where the folder pane is scrolled to: the first visible row and its offset in pixels. */
data class FolderPaneScroll(
    val index: Int = 0,
    val offset: Int = 0,
)

class FoldersViewModel(
    private val container: AppContainer,
) : ViewModel() {
    private val mutableState = MutableStateFlow(FoldersUiState())
    val state: StateFlow<FoldersUiState> = mutableState.asStateFlow()

    /**
     * The wide-window pane's scroll position. Opening a folder replaces the
     * messages entry, and the pane inside it, so the position lives here with
     * the folder list rather than in the pane's own list state, which starts
     * over at the top on each switch — the same shape as the feeds tab's
     * [com.cabalmail.android.ui.feeds.FeedTreeScroll].
     */
    var paneScroll: FolderPaneScroll = FolderPaneScroll()

    init {
        refresh()
    }

    fun refresh() = refresh(quiet = false)

    /** Foreground poll (plan §7.3): same reload, no spinner, errors stay silent. */
    fun poll() = refresh(quiet = true)

    private fun refresh(quiet: Boolean) {
        viewModelScope.launch {
            if (!quiet) {
                mutableState.update { it.copy(refreshing = true, error = null) }
            }
            try {
                val api = container.requireApi()
                val list = api.listFolders()
                val folders = list.folders
                val subscribed = list.subscribedFolders.toSet()
                mutableState.update {
                    it.copy(folders = folders, subscribed = subscribed, refreshing = false, error = null)
                }
                loadStatuses(api, folders, subscribed, includeAll = currentFilter().needsAllStatuses)
            } catch (exception: Exception) {
                if (!quiet) {
                    mutableState.update {
                        it.copy(refreshing = false, error = userMessage(exception, "Could not load folders"))
                    }
                }
            }
        }
    }

    /**
     * Unread badges arrive as their STATUS calls land; a folder whose
     * STATUS fails just keeps whatever it showed. Proactive STATUS is
     * scoped to subscribed folders (see [FolderSections.statusTargets])
     * unless the filter needs every folder's count. Results merge into the
     * map already held, so a subscribed-only pass never discards counts an
     * all-folder pass fetched earlier; folders no longer listed drop out.
     */
    private suspend fun loadStatuses(
        api: ApiClient,
        folders: List<String>,
        subscribed: Set<String>,
        includeAll: Boolean,
    ) = coroutineScope {
        val statuses =
            FolderSections
                .statusTargets(folders, subscribed, includeAll)
                .map { folder ->
                    async {
                        folder to runCatching { api.folderStatus(folder) }.getOrNull()
                    }
                }.awaitAll()
                .mapNotNull { (folder, status) -> status?.let { folder to it } }
                .toMap()
        mutableState.update { it.copy(statuses = (it.statuses + statuses).filterKeys { key -> key in folders }) }
    }

    private fun currentFilter(): FolderListFilter = container.preferences.preferences.value.folderListFilter

    /**
     * Applies a tap on a pill (see [FolderListFilter.toggled]); persisted
     * on the device via preferences. Flipping into Unread-without-Subscribed
     * walks STATUS for every folder, since the list cannot be honest about
     * unsubscribed folders with only the subscribed counts in hand.
     */
    fun setFilter(pill: FolderFilterPill) {
        viewModelScope.launch {
            val before = currentFilter()
            val after = before.toggled(pill)
            container.preferences.update { prefs ->
                prefs.copy(folderFilterSubscribed = after.subscribed, folderFilterUnread = after.unread)
            }
            if (after.needsAllStatuses && !before.needsAllStatuses) {
                val snapshot = mutableState.value
                val folders = snapshot.folders ?: return@launch
                try {
                    loadStatuses(container.requireApi(), folders, snapshot.subscribed, includeAll = true)
                } catch (_: Exception) {
                    // No API yet (signed out, config not loaded): the list
                    // shows the counts it has; the next refresh fills in.
                }
            }
        }
    }

    /** Expunges everything in Trash (server-side trash-scoped). */
    fun emptyTrash() {
        viewModelScope.launch {
            try {
                container.requireApi().emptyTrash(TRASH_FOLDER)
                container.envelopeCache.invalidateFolder(TRASH_FOLDER)
                refresh()
            } catch (exception: Exception) {
                mutableState.update {
                    it.copy(error = userMessage(exception, "Could not empty Trash"))
                }
            }
        }
    }

    companion object {
        const val TRASH_FOLDER = "Trash"

        fun factory(container: AppContainer): ViewModelProvider.Factory =
            viewModelFactory {
                initializer { FoldersViewModel(container) }
            }
    }
}

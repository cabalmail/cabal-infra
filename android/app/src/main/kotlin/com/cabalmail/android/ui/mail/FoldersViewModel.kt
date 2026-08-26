package com.cabalmail.android.ui.mail

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import com.cabalmail.android.AppContainer
import com.cabalmail.android.userMessage
import com.cabalmail.kit.models.FolderStatus
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
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

class FoldersViewModel(
    private val container: AppContainer,
) : ViewModel() {
    private val mutableState = MutableStateFlow(FoldersUiState())
    val state: StateFlow<FoldersUiState> = mutableState.asStateFlow()

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
                // Unread badges arrive as their STATUS calls land; a folder
                // whose STATUS fails just shows no badge. Proactive STATUS
                // is scoped to subscribed folders (see FolderSections).
                val statuses =
                    FolderSections
                        .statusTargets(folders, subscribed)
                        .map { folder ->
                            async {
                                folder to runCatching { api.folderStatus(folder) }.getOrNull()
                            }
                        }.awaitAll()
                        .mapNotNull { (folder, status) -> status?.let { folder to it } }
                        .toMap()
                mutableState.update { it.copy(statuses = statuses) }
            } catch (exception: Exception) {
                if (!quiet) {
                    mutableState.update {
                        it.copy(refreshing = false, error = userMessage(exception, "Could not load folders"))
                    }
                }
            }
        }
    }

    /** Flips a section's disclosure; persisted on the device via preferences. */
    fun toggleSection(section: FolderSection) {
        viewModelScope.launch {
            container.preferences.update { prefs ->
                when (section) {
                    FolderSection.SUBSCRIBED ->
                        prefs.copy(folderSectionSubscribedExpanded = !prefs.folderSectionSubscribedExpanded)
                    FolderSection.ALL ->
                        prefs.copy(folderSectionAllExpanded = !prefs.folderSectionAllExpanded)
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

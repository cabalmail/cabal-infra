package com.cabalmail.android.ui.folders

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import com.cabalmail.android.AppContainer
import com.cabalmail.kit.models.FolderList
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

data class FoldersAdminUiState(
    /** Every folder, server order; null until loaded. */
    val folders: List<String>? = null,
    val subscribed: Set<String> = emptySet(),
    /** Message counts, as STATUS calls land; gates the delete action. */
    val counts: Map<String, Int> = emptyMap(),
    val refreshing: Boolean = false,
    /** Folders with a mutation in flight. */
    val busy: Set<String> = emptySet(),
    val creating: Boolean = false,
    val error: String? = null,
)

/** The Folders admin screen (plan §6.2): subscribe / unsubscribe / create / delete. */
class FoldersAdminViewModel(
    private val container: AppContainer,
) : ViewModel() {
    private val mutableState = MutableStateFlow(FoldersAdminUiState())
    val state: StateFlow<FoldersAdminUiState> = mutableState.asStateFlow()

    init {
        refresh()
    }

    fun refresh() {
        viewModelScope.launch {
            mutableState.update { it.copy(refreshing = true, error = null) }
            try {
                val api = container.requireApi()
                apply(api.listFolders())
                mutableState.update { it.copy(refreshing = false) }
                loadCounts()
            } catch (exception: Exception) {
                mutableState.update {
                    it.copy(refreshing = false, error = exception.message ?: "Could not load folders")
                }
            }
        }
    }

    private fun apply(list: FolderList) {
        mutableState.update {
            it.copy(folders = list.folders, subscribed = list.subscribedFolders.toSet())
        }
    }

    private fun loadCounts() {
        viewModelScope.launch {
            val api = container.requireApi()
            val folders = mutableState.value.folders.orEmpty()
            val counts =
                folders
                    .map { folder ->
                        async { folder to runCatching { api.folderStatus(folder).messages }.getOrNull() }
                    }.awaitAll()
                    .mapNotNull { (folder, count) -> count?.let { folder to it } }
                    .toMap()
            mutableState.update { it.copy(counts = counts) }
        }
    }

    fun setSubscribed(
        folder: String,
        subscribed: Boolean,
    ) {
        mutate(folder, "Could not update subscription") { api ->
            if (subscribed) api.subscribeFolder(folder) else api.unsubscribeFolder(folder)
            mutableState.update {
                it.copy(subscribed = if (subscribed) it.subscribed + folder else it.subscribed - folder)
            }
        }
    }

    /** Deletes [folder]; the server refuses non-empty and system folders. */
    fun delete(folder: String) {
        mutate(folder, "Could not delete folder") { api ->
            apply(api.deleteFolder(folder))
            container.envelopeCache.invalidateFolder(folder)
        }
    }

    fun create(
        name: String,
        parent: String,
        onCreated: () -> Unit,
    ) {
        val trimmed = name.trim()
        if (trimmed.isEmpty()) {
            return
        }
        mutableState.update { it.copy(creating = true, error = null) }
        viewModelScope.launch {
            try {
                apply(container.requireApi().newFolder(trimmed, parent))
                mutableState.update { it.copy(creating = false) }
                onCreated()
                loadCounts()
            } catch (exception: Exception) {
                mutableState.update {
                    it.copy(creating = false, error = exception.message ?: "Could not create folder")
                }
            }
        }
    }

    private fun mutate(
        folder: String,
        failure: String,
        block: suspend (com.cabalmail.kit.api.ApiClient) -> Unit,
    ) {
        if (folder in mutableState.value.busy) {
            return
        }
        mutableState.update { it.copy(busy = it.busy + folder, error = null) }
        viewModelScope.launch {
            try {
                block(container.requireApi())
                mutableState.update { it.copy(busy = it.busy - folder) }
            } catch (exception: Exception) {
                mutableState.update { it.copy(busy = it.busy - folder, error = exception.message ?: failure) }
            }
        }
    }

    fun clearError() {
        mutableState.update { it.copy(error = null) }
    }

    /** System folders are never deletable; user folders only when empty. */
    fun canDelete(folder: String): Boolean = folder !in SYSTEM_FOLDERS && (mutableState.value.counts[folder] ?: 0) == 0

    companion object {
        val SYSTEM_FOLDERS = setOf("INBOX", "Sent", "Drafts", "Trash", "Junk", "Archive", "Outbox")

        fun factory(container: AppContainer): ViewModelProvider.Factory =
            viewModelFactory {
                initializer { FoldersAdminViewModel(container) }
            }
    }
}

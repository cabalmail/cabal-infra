package com.cabalmail.android.ui.mail

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import com.cabalmail.android.AppContainer
import com.cabalmail.android.userMessage
import com.cabalmail.kit.models.Envelope
import com.cabalmail.kit.models.SearchFilters
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

private val DAY_STAMP = Regex("""\d{4}-\d{2}-\d{2}""")

data class SearchUiState(
    val query: String = "",
    val filters: SearchFilters = SearchFilters(),
    /** Restrict to the folder this screen was opened from. */
    val folderOnly: Boolean = false,
    val results: List<Envelope> = emptyList(),
    val searching: Boolean = false,
    /** Opaque next-page cursor; null = no further pages. */
    val cursor: String? = null,
    /** At least one search has run (distinguishes "no results" from idle). */
    val searched: Boolean = false,
    val truncated: Boolean = false,
    val showFilters: Boolean = false,
    val error: String? = null,
)

/**
 * The plan's first-class search scope: structured predicates over
 * `/search_envelopes`, cross-folder by default (server side: subscribed
 * folders minus Trash, merged newest-first), opaque-cursor paging. Every
 * result carries its source folder so per-row operations route there.
 */
class SearchViewModel(
    private val container: AppContainer,
    /** Folder the search was opened from; enables "this folder only". */
    val scopeFolder: String?,
) : ViewModel() {
    private val mutableState = MutableStateFlow(SearchUiState())
    val state: StateFlow<SearchUiState> = mutableState.asStateFlow()

    /**
     * Folder/UID pairs with a dispose in flight; a repeat request is dropped
     * so a message is never moved twice concurrently (Dovecot would land two
     * copies in the destination).
     */
    private val disposing = mutableSetOf<Pair<String, Long>>()

    fun setQuery(query: String) {
        mutableState.update { it.copy(query = query) }
    }

    fun updateFilters(transform: (SearchFilters) -> SearchFilters) {
        mutableState.update { it.copy(filters = transform(it.filters)) }
    }

    fun setFolderOnly(folderOnly: Boolean) {
        mutableState.update { it.copy(folderOnly = folderOnly) }
    }

    fun setShowFilters(show: Boolean) {
        mutableState.update { it.copy(showFilters = show) }
    }

    /** Runs a fresh search from the first page. */
    fun search() {
        val current = mutableState.value
        val dates = listOfNotNull(current.filters.since, current.filters.before)
        if (dates.any { !DAY_STAMP.matches(it) }) {
            mutableState.update { it.copy(error = "Dates must be YYYY-MM-DD") }
            return
        }
        mutableState.update {
            it.copy(results = emptyList(), cursor = null, showFilters = false, error = null)
        }
        fetchPage(reset = true)
    }

    /** Fetches the next page; no-op while a fetch is in flight or at the end. */
    fun loadMore() {
        val current = mutableState.value
        if (current.searching || current.cursor == null) {
            return
        }
        fetchPage(reset = false)
    }

    private fun fetchPage(reset: Boolean) {
        viewModelScope.launch {
            mutableState.update { it.copy(searching = true, error = null) }
            try {
                val current = mutableState.value
                val result =
                    container.requireApi().searchEnvelopes(
                        text = current.query.takeIf { it.isNotBlank() },
                        filters = sanitized(current.filters),
                        folder = scopeFolder.takeIf { current.folderOnly },
                        cursor = if (reset) null else current.cursor,
                    )
                mutableState.update { state ->
                    state.copy(
                        results = state.results + result.envelopes,
                        cursor = result.nextCursor,
                        truncated = result.truncated,
                        searching = false,
                        searched = true,
                    )
                }
            } catch (exception: Exception) {
                mutableState.update {
                    it.copy(searching = false, error = userMessage(exception, "Search failed"))
                }
            }
        }
    }

    private fun sanitized(filters: SearchFilters): SearchFilters =
        filters.copy(
            from = filters.from?.trim()?.takeIf { it.isNotEmpty() },
            to = filters.to?.trim()?.takeIf { it.isNotEmpty() },
            subject = filters.subject?.trim()?.takeIf { it.isNotEmpty() },
            since = filters.since?.trim()?.takeIf { it.isNotEmpty() },
            before = filters.before?.trim()?.takeIf { it.isNotEmpty() },
        )

    // --------------------------------------------- per-row operations
    // Search rows span folders, so every operation routes through the
    // envelope's own source folder.

    fun toggleSeen(envelope: Envelope) {
        setFlag(envelope, "\\Seen", !envelope.isSeen)
    }

    fun toggleFlag(envelope: Envelope) {
        setFlag(envelope, "\\Flagged", !envelope.isFlagged)
    }

    /**
     * Archive, or (post-confirmation) purge when the source is Trash. An
     * archived message is also marked read (archived == read), in the same
     * server call so the flag is set before the MOVE drops the source UID.
     */
    fun dispose(envelope: Envelope) {
        val folder = envelope.folder ?: return
        if (!disposing.add(folder to envelope.id)) {
            return
        }
        viewModelScope.launch {
            try {
                val api = container.requireApi()
                if (folder == "Trash") {
                    api.purgeMessages(folder, listOf(envelope.id))
                    container.bodyCache.remove(folder, envelope.id)
                } else {
                    api.moveMessages(
                        folder,
                        MessageListViewModel.disposeTarget(container.preferences.preferences.value),
                        listOf(envelope.id),
                        markSeen = true,
                    )
                }
                container.envelopeCache.invalidateFolder(folder)
                mutableState.update { state ->
                    state.copy(results = state.results.filterNot { it.id == envelope.id && it.folder == folder })
                }
            } catch (exception: Exception) {
                mutableState.update { it.copy(error = userMessage(exception, "Could not move message")) }
            } finally {
                disposing.remove(folder to envelope.id)
            }
        }
    }

    private fun setFlag(
        envelope: Envelope,
        flag: String,
        value: Boolean,
    ) {
        val folder = envelope.folder ?: return
        viewModelScope.launch {
            try {
                container.requireApi().setFlag(folder, listOf(envelope.id), flag, value)
                val flags =
                    if (value) {
                        (envelope.flags + flag).distinct()
                    } else {
                        envelope.flags.filterNot { it.equals(flag, ignoreCase = true) }
                    }
                val patched = envelope.copy(flags = flags)
                container.envelopeCache.write(folder, listOf(patched))
                mutableState.update { state ->
                    state.copy(
                        results =
                            state.results.map {
                                if (it.id == envelope.id && it.folder == folder) patched else it
                            },
                    )
                }
            } catch (exception: Exception) {
                mutableState.update { it.copy(error = userMessage(exception, "Could not update flags")) }
            }
        }
    }

    companion object {
        fun factory(
            container: AppContainer,
            scopeFolder: String?,
        ): ViewModelProvider.Factory =
            viewModelFactory {
                initializer { SearchViewModel(container, scopeFolder) }
            }
    }
}

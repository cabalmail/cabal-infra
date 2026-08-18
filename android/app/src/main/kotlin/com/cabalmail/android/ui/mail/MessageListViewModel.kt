package com.cabalmail.android.ui.mail

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import com.cabalmail.android.AppContainer
import com.cabalmail.kit.models.Envelope
import com.cabalmail.kit.settings.AppPreferences
import com.cabalmail.kit.settings.DefaultSort
import com.cabalmail.kit.settings.DisposeAction
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

/** The plan's sort options, by IMAP SORT key. */
enum class MessageSortField(
    val wire: String,
) {
    DATE_RECEIVED("ARRIVAL"),
    DATE_SENT("DATE"),
    FROM("FROM"),
    SUBJECT("SUBJECT"),
}

/** Display narrowing over the loaded window; never a server query. */
enum class MessageFilter { ALL, UNREAD, FLAGGED }

data class FolderCounts(
    val all: Int,
    val unseen: Int,
    val flagged: Int,
) {
    /** Adjusts the affected pill count after [gained] rows gained [flag]. */
    fun adjustedFor(
        flag: String,
        gained: Int,
    ): FolderCounts =
        when {
            flag.equals("\\Seen", ignoreCase = true) -> copy(unseen = (unseen - gained).coerceAtLeast(0))
            flag.equals("\\Flagged", ignoreCase = true) -> copy(flagged = (flagged + gained).coerceAtLeast(0))
            else -> this
        }
}

data class MessageListUiState(
    /** Total messages in the folder; null until the first page lands. */
    val total: Int? = null,
    /** Loaded envelopes keyed by list index (0 = newest under the sort). */
    val envelopes: Map<Int, Envelope> = emptyMap(),
    val refreshing: Boolean = false,
    val error: String? = null,
    val sortField: MessageSortField = MessageSortField.DATE_RECEIVED,
    val sortDescending: Boolean = true,
    val filter: MessageFilter = MessageFilter.ALL,
    val counts: FolderCounts? = null,
    /** Selection mode: rows become checkboxes, the top bar turns contextual. */
    val selecting: Boolean = false,
    val selected: Set<Long> = emptySet(),
    /** A bulk mutation is in flight. */
    val busy: Boolean = false,
    /** Move-destination choices; null until requested. */
    val folderChoices: List<String>? = null,
) {
    /**
     * The loaded rows that survive the active filter pill, in window order.
     * Meaningful only when [filter] is not ALL — the unfiltered list renders
     * by index with placeholders instead.
     */
    val filteredRows: List<Envelope>
        get() =
            envelopes.entries
                .sortedBy { it.key }
                .map { it.value }
                .filter { envelope ->
                    when (filter) {
                        MessageFilter.ALL -> true
                        MessageFilter.UNREAD -> !envelope.isSeen
                        MessageFilter.FLAGGED -> envelope.isFlagged
                    }
                }
}

/**
 * Drops [removed] UIDs from an index-keyed window, shifting higher indices
 * down so the window stays aligned with the server's post-removal order
 * (the server compacts identically when messages leave the folder).
 */
internal fun compactWindow(
    envelopes: Map<Int, Envelope>,
    removed: Set<Long>,
): Map<Int, Envelope> {
    val removedIndices =
        envelopes.entries.filter { it.value.id in removed }.map { it.key }.sorted()
    if (removedIndices.isEmpty()) {
        return envelopes
    }
    return buildMap {
        envelopes.forEach { (index, envelope) ->
            if (envelope.id !in removed) {
                put(index - removedIndices.count { it < index }, envelope)
            }
        }
    }
}

/**
 * Index-addressed sliding window over one folder, mirroring the Apple
 * client's virtualization: `/list_messages` (server-side SORT) supplies the
 * total plus per-band UID pages, `/list_envelopes` fills the band, and the
 * envelope cache short-circuits both on revisit. Placeholder rows render
 * for indices whose band hasn't landed.
 */
class MessageListViewModel(
    private val container: AppContainer,
    private val folder: String,
) : ViewModel() {
    private val mutableState = MutableStateFlow(MessageListUiState())
    val state: StateFlow<MessageListUiState> = mutableState.asStateFlow()

    private val requestedBands = mutableSetOf<Int>()
    private var uidValidity: Long? = null

    val isTrashFolder: Boolean = folder == "Trash"

    init {
        // Default sort (plan §6.3): a local preference seeds the first load.
        val prefs = container.preferences.preferences.value
        mutableState.update {
            it.copy(
                sortField =
                    when (prefs.defaultSort) {
                        DefaultSort.RECEIVED -> MessageSortField.DATE_RECEIVED
                        DefaultSort.SENT -> MessageSortField.DATE_SENT
                        DefaultSort.FROM -> MessageSortField.FROM
                        DefaultSort.SUBJECT -> MessageSortField.SUBJECT
                    },
                sortDescending = prefs.defaultSortDescending,
            )
        }
        refresh()
    }

    /** The "Dispose action" preference's target folder (plan §6.3). */
    private fun disposeFolder(): String = disposeTarget(container.preferences.preferences.value)

    fun refresh() {
        viewModelScope.launch {
            mutableState.update { it.copy(refreshing = true, error = null) }
            requestedBands.clear()
            try {
                val api = container.requireApi()
                val status = api.folderStatus(folder, includeFlagged = true)
                uidValidity = status.uidValidity
                status.uidValidity?.let { container.envelopeCache.reconcile(folder, it) }
                mutableState.update { state ->
                    state.copy(
                        total = status.messages,
                        envelopes = emptyMap(),
                        refreshing = false,
                        counts =
                            FolderCounts(
                                all = status.messages ?: 0,
                                unseen = status.unseen ?: 0,
                                flagged = status.flagged ?: 0,
                            ),
                        selected = emptySet(),
                        selecting = false,
                    )
                }
                ensureBand(0)
            } catch (exception: Exception) {
                mutableState.update {
                    it.copy(refreshing = false, error = exception.message ?: "Could not load $folder")
                }
            }
        }
    }

    // ------------------------------------------------------- sort and filter

    fun setSort(
        field: MessageSortField,
        descending: Boolean,
    ) {
        val current = mutableState.value
        if (current.sortField == field && current.sortDescending == descending) {
            return
        }
        requestedBands.clear()
        mutableState.update {
            it.copy(sortField = field, sortDescending = descending, envelopes = emptyMap())
        }
        ensureBand(0)
    }

    fun setFilter(filter: MessageFilter) {
        mutableState.update { it.copy(filter = filter) }
    }

    // ------------------------------------------------------------ windowing

    /** Called from the list's visible-range effect. */
    fun onVisibleRange(
        firstIndex: Int,
        lastIndex: Int,
    ) {
        (firstIndex / BAND_SIZE..lastIndex / BAND_SIZE).forEach(::ensureBand)
        container.navCursor.record(folder = folder, listScroll = firstIndex.toLong())
    }

    /**
     * Under an active filter pill the row indices no longer map to window
     * indices, so nearing the end of the filtered rows just requests the
     * next unloaded band.
     */
    fun requestMoreForFilter() {
        val total = mutableState.value.total ?: return
        val bandCount = (total + BAND_SIZE - 1) / BAND_SIZE
        (0 until bandCount).firstOrNull { it !in requestedBands }?.let(::ensureBand)
    }

    private fun ensureBand(band: Int) {
        if (band < 0 || !requestedBands.add(band)) {
            return
        }
        viewModelScope.launch {
            try {
                val api = container.requireApi()
                val sort = mutableState.value
                val offset = band * BAND_SIZE
                val page =
                    api.listMessages(
                        folder,
                        sortField = sort.sortField.wire,
                        descending = sort.sortDescending,
                        offset = offset,
                        limit = BAND_SIZE,
                    )
                val uids = page.messageIds
                val cached = container.envelopeCache.read(folder, uids)
                val missing = uids.filterNot(cached::containsKey)
                val fetched =
                    if (missing.isEmpty()) {
                        emptyMap()
                    } else {
                        api.listEnvelopes(folder, missing).also { fresh ->
                            container.envelopeCache.write(folder, fresh.values)
                        }
                    }
                val byUid = cached + fetched
                mutableState.update { state ->
                    state.copy(
                        total = page.total,
                        envelopes =
                            state.envelopes +
                                uids.mapIndexedNotNull { i, uid ->
                                    byUid[uid]?.let { (offset + i) to it }
                                },
                    )
                }
            } catch (exception: Exception) {
                // A failed band may be retried on the next scroll past it.
                requestedBands.remove(band)
                mutableState.update {
                    it.copy(error = exception.message ?: "Could not load messages")
                }
            }
        }
    }

    // ------------------------------------------------------------ selection

    fun startSelecting() {
        mutableState.update { it.copy(selecting = true) }
    }

    fun stopSelecting() {
        mutableState.update { it.copy(selecting = false, selected = emptySet()) }
    }

    fun toggleSelected(uid: Long) {
        mutableState.update { state ->
            val selected =
                if (uid in state.selected) state.selected - uid else state.selected + uid
            state.copy(selected = selected)
        }
    }

    // ------------------------------------------------------------ mutations

    /** Sets or clears one flag on [uids] and patches the loaded copies. */
    fun setFlag(
        uids: Set<Long>,
        flag: String,
        value: Boolean,
    ) {
        if (uids.isEmpty()) {
            return
        }
        viewModelScope.launch {
            try {
                container.requireApi().setFlag(folder, uids.toList(), flag, value)
                patchFlags(uids, flag, value)
            } catch (exception: Exception) {
                mutableState.update { it.copy(error = exception.message ?: "Could not update flags") }
            }
        }
    }

    /**
     * Moves [uids] to [destination] and compacts the window. Selection
     * clears afterwards, per the plan's bulk-selection semantics.
     */
    fun move(
        uids: Set<Long>,
        destination: String,
    ) {
        if (uids.isEmpty()) {
            return
        }
        viewModelScope.launch {
            mutableState.update { it.copy(busy = true, error = null) }
            try {
                container.requireApi().moveMessages(folder, destination, uids.toList())
                container.envelopeCache.invalidateFolder(folder)
                removeFromWindow(uids)
            } catch (exception: Exception) {
                mutableState.update {
                    it.copy(busy = false, error = exception.message ?: "Could not move messages")
                }
            }
        }
    }

    /** The dispose action: archive, or (from Trash, post-confirmation) purge. */
    fun dispose(uids: Set<Long>) {
        if (uids.isEmpty()) {
            return
        }
        if (!isTrashFolder) {
            move(uids, disposeFolder())
            return
        }
        viewModelScope.launch {
            mutableState.update { it.copy(busy = true, error = null) }
            try {
                container.requireApi().purgeMessages(folder, uids.toList())
                container.envelopeCache.invalidateFolder(folder)
                uids.forEach { container.bodyCache.remove(folder, it) }
                removeFromWindow(uids)
            } catch (exception: Exception) {
                mutableState.update {
                    it.copy(busy = false, error = exception.message ?: "Could not delete messages")
                }
            }
        }
    }

    /** Lazily loads the move-destination folder list. */
    fun loadFolderChoices() {
        if (mutableState.value.folderChoices != null) {
            return
        }
        viewModelScope.launch {
            try {
                val folders = container.requireApi().listFolders().folders
                mutableState.update { state ->
                    state.copy(folderChoices = folders.filterNot { it == folder })
                }
            } catch (exception: Exception) {
                mutableState.update { it.copy(error = exception.message ?: "Could not load folders") }
            }
        }
    }

    private fun patchFlags(
        uids: Set<Long>,
        flag: String,
        value: Boolean,
    ) {
        mutableState.update { state ->
            // Count actual transitions so the pill counts track the server
            // without a re-STATUS; a no-op set leaves them untouched.
            val changed =
                state.envelopes.values.count { envelope ->
                    envelope.id in uids && envelope.flags.any { it.equals(flag, ignoreCase = true) } != value
                }
            val gained = if (value) changed else -changed
            state.copy(
                envelopes =
                    state.envelopes.mapValues { (_, envelope) ->
                        if (envelope.id !in uids) {
                            envelope
                        } else {
                            val flags =
                                if (value) {
                                    (envelope.flags + flag).distinct()
                                } else {
                                    envelope.flags.filterNot { it.equals(flag, ignoreCase = true) }
                                }
                            envelope.copy(flags = flags)
                        }
                    },
                counts = state.counts?.adjustedFor(flag, gained),
            )
        }
        val patched = mutableState.value.envelopes.values.filter { it.id in uids }
        viewModelScope.launch {
            container.envelopeCache.write(folder, patched)
        }
    }

    private fun removeFromWindow(uids: Set<Long>) {
        // Bands no longer align exactly after a removal; drop the request
        // markers so any gap re-requests on the next scroll past it.
        requestedBands.clear()
        mutableState.update { state ->
            val removed = state.envelopes.values.filter { it.id in uids }
            state.copy(
                envelopes = compactWindow(state.envelopes, uids),
                total = state.total?.let { (it - uids.size).coerceAtLeast(0) },
                counts =
                    state.counts?.let { counts ->
                        counts.copy(
                            all = (counts.all - uids.size).coerceAtLeast(0),
                            unseen = (counts.unseen - removed.count { !it.isSeen }).coerceAtLeast(0),
                            flagged = (counts.flagged - removed.count { it.isFlagged }).coerceAtLeast(0),
                        )
                    },
                selected = emptySet(),
                selecting = false,
                busy = false,
            )
        }
    }

    companion object {
        const val BAND_SIZE = 50
        const val ARCHIVE_FOLDER = "Archive"
        const val TRASH_FOLDER = "Trash"

        /** The dispose target for a non-Trash folder under [prefs]. */
        fun disposeTarget(prefs: AppPreferences): String =
            when (prefs.disposeAction) {
                DisposeAction.ARCHIVE -> ARCHIVE_FOLDER
                DisposeAction.TRASH -> TRASH_FOLDER
            }

        fun factory(
            container: AppContainer,
            folder: String,
        ): ViewModelProvider.Factory =
            viewModelFactory {
                initializer { MessageListViewModel(container, folder) }
            }
    }
}

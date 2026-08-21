package com.cabalmail.android.ui.mail

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import com.cabalmail.android.AppContainer
import com.cabalmail.android.MailEvent
import com.cabalmail.android.userMessage
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
        envelopes.entries
            .filter { it.value.id in removed }
            .map { it.key }
            .sorted()
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
 * Merges a fetched band ([uids] in server order at [offset], envelopes in
 * [byUid]) into an index-keyed window. Any stale copy of the band's UIDs is
 * evicted first: when the folder shifted underneath the window (new mail, a
 * removal), a refetched band re-places a UID at a new index, and the old
 * entry would leave the same message at two indices — a duplicate row, and
 * a duplicate key for the UID-keyed list. UIDs missing from [byUid] leave
 * their index unloaded (a placeholder row).
 */
internal fun mergeBand(
    envelopes: Map<Int, Envelope>,
    offset: Int,
    uids: List<Long>,
    byUid: Map<Long, Envelope>,
): Map<Int, Envelope> {
    val bandUids = uids.toSet()
    return envelopes.filterNot { it.value.id in bandUids } +
        uids.mapIndexedNotNull { i, uid ->
            byUid[uid]?.let { (offset + i) to it }
        }
}

/**
 * The server copy of a refetched band wins over the loaded window — except
 * rows whose own flag write is still in flight, where the optimistic local
 * copy stands until the write settles (the Apple client's pending-write
 * shield). Without the shield, a refetch racing the user's tap would
 * briefly revert the star, and the confirmed write would then persist the
 * reverted copy.
 */
internal fun shieldPendingWrites(
    fetched: Map<Long, Envelope>,
    window: Collection<Envelope>,
    inFlight: (Long) -> Boolean,
): Map<Long, Envelope> =
    fetched +
        window
            .filter { it.id in fetched && inFlight(it.id) }
            .associateBy { it.id }

/**
 * Index-addressed sliding window over one folder, mirroring the Apple
 * client's virtualization: `/list_messages` (server-side SORT) supplies the
 * total plus per-band UID pages and `/list_envelopes` fills the band. A
 * revisited band paints from the envelope cache while the fill is in
 * flight, but the fill always completes and the server copy wins: flags
 * change underneath the cache (another client marking a message read, or
 * clearing a star), so a cached envelope is a warm start, never the
 * answer. Placeholder rows render for indices whose band hasn't landed.
 */
class MessageListViewModel(
    internal val container: AppContainer,
    private val folder: String,
) : ViewModel() {
    private val mutableState = MutableStateFlow(MessageListUiState())
    val state: StateFlow<MessageListUiState> = mutableState.asStateFlow()

    private val requestedBands = mutableSetOf<Int>()

    /**
     * UIDs with a move or purge already in flight. A second request for the
     * same UID is dropped rather than sent: Dovecot runs concurrent MOVEs of
     * one message independently, so two overlapping requests land two copies
     * in the destination (or the later one fails once the first has expunged
     * the source), and the swipe surface can fire its callback more than once
     * per gesture.
     */
    private val removing = mutableSetOf<Long>()
    private var uidValidity: Long? = null
    private var lastUidNext: Long? = null

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
        // Mirror reader-side changes (flags, disposals) into the window.
        viewModelScope.launch {
            container.mailEvents.events.collect { event ->
                if (event.folder != folder) {
                    return@collect
                }
                when (event) {
                    is MailEvent.FlagChanged -> patchFlags(event.uids, event.flag, event.value)
                    is MailEvent.Removed -> removeFromWindow(event.uids)
                    is MailEvent.Reconcile -> refresh()
                }
            }
        }
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
                lastUidNext = status.uidNext
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
                    it.copy(refreshing = false, error = userMessage(exception, "Could not load $folder"))
                }
            }
        }
    }

    /**
     * Foreground poll (plan §7.3): a cheap STATUS, and a real reload only
     * when the folder changed underneath us. Never disturbs a selection.
     */
    fun poll() {
        val current = mutableState.value
        // writesInFlight: an optimistic mutation (from any screen) hasn't
        // been confirmed yet, so a STATUS now would read as a folder change
        // and the reload would resurrect rows the user watched leave.
        if (current.refreshing || current.selecting || container.mailEvents.writesInFlight) {
            return
        }
        viewModelScope.launch {
            val status =
                runCatching { container.requireApi().folderStatus(folder, includeFlagged = true) }.getOrNull()
                    ?: return@launch
            val changed =
                status.uidNext != lastUidNext ||
                    status.uidValidity != uidValidity ||
                    status.messages != current.total
            if (changed) {
                refresh()
            } else {
                mutableState.update {
                    it.copy(
                        counts =
                            FolderCounts(
                                all = status.messages ?: 0,
                                unseen = status.unseen ?: 0,
                                flagged = status.flagged ?: 0,
                            ),
                    )
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
                if (cached.isNotEmpty()) {
                    mutableState.update { state ->
                        state.copy(
                            total = page.total,
                            envelopes = mergeBand(state.envelopes, offset, uids, cached),
                        )
                    }
                }
                val fetched = api.listEnvelopes(folder, uids)
                container.envelopeCache.write(
                    folder,
                    fetched.values.filterNot { container.mailEvents.flagWriteInFlight(folder, it.id) },
                )
                mutableState.update { state ->
                    val byUid =
                        shieldPendingWrites(fetched, state.envelopes.values) {
                            container.mailEvents.flagWriteInFlight(folder, it)
                        }
                    state.copy(
                        total = page.total,
                        envelopes = mergeBand(state.envelopes, offset, uids, byUid),
                    )
                }
            } catch (exception: Exception) {
                // A failed band may be retried on the next scroll past it.
                requestedBands.remove(band)
                mutableState.update {
                    it.copy(error = userMessage(exception, "Could not load messages"))
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
    // All of these apply optimistically: the window, pills, and total move
    // before the server confirms, because success is the overwhelmingly
    // common case. The envelope cache is only written (or invalidated) once
    // the server has agreed, and a failure surfaces the error and refetches
    // true state.

    /** Sets or clears one flag on [uids] and patches the loaded copies. */
    fun setFlag(
        uids: Set<Long>,
        flag: String,
        value: Boolean,
    ) {
        if (uids.isEmpty()) {
            return
        }
        patchFlags(uids, flag, value)
        container.mailEvents.beginFlagWrite(folder, uids)
        viewModelScope.launch {
            try {
                container.requireApi().setFlag(folder, uids.toList(), flag, value)
                writeWindowToCache(uids)
            } catch (exception: Exception) {
                mutableState.update { it.copy(error = userMessage(exception, "Could not update flags")) }
                refresh()
            } finally {
                container.mailEvents.endFlagWrite(folder, uids)
            }
        }
    }

    /**
     * Moves [uids] to [destination] and compacts the window. Selection
     * clears with the removal, per the plan's bulk-selection semantics.
     * UIDs already being moved or purged are skipped (see [removing]).
     */
    fun move(
        uids: Set<Long>,
        destination: String,
        markSeen: Boolean = false,
    ) {
        val fresh = claimForRemoval(uids) ?: return
        removeFromWindow(fresh)
        container.mailEvents.beginWrite()
        viewModelScope.launch {
            try {
                container.requireApi().moveMessages(folder, destination, fresh.toList(), markSeen = markSeen)
                container.envelopeCache.invalidateFolder(folder)
            } catch (exception: Exception) {
                mutableState.update { it.copy(error = userMessage(exception, "Could not move messages")) }
                refresh()
            } finally {
                container.mailEvents.endWrite()
                removing.removeAll(fresh)
            }
        }
    }

    /**
     * The dispose action: archive, or (from Trash, post-confirmation) purge.
     * A disposed message is also marked read — archived == read, matching the
     * Apple and React clients — in the same server call, so the flag lands
     * before the MOVE takes the UID out of the source folder.
     */
    fun dispose(uids: Set<Long>) {
        if (!isTrashFolder) {
            move(uids, disposeFolder(), markSeen = true)
            return
        }
        val fresh = claimForRemoval(uids) ?: return
        removeFromWindow(fresh)
        container.mailEvents.beginWrite()
        viewModelScope.launch {
            try {
                container.requireApi().purgeMessages(folder, fresh.toList())
                container.envelopeCache.invalidateFolder(folder)
                fresh.forEach { container.bodyCache.remove(folder, it) }
            } catch (exception: Exception) {
                mutableState.update { it.copy(error = userMessage(exception, "Could not delete messages")) }
                refresh()
            } finally {
                container.mailEvents.endWrite()
                removing.removeAll(fresh)
            }
        }
    }

    /**
     * Reserves the UIDs in [uids] that have no removal in flight, or null
     * when nothing is left to do. Runs on the main thread (all entry points
     * are UI callbacks), so the check-and-insert is not racy.
     */
    private fun claimForRemoval(uids: Set<Long>): Set<Long>? {
        val fresh = uids - removing
        if (fresh.isEmpty()) {
            return null
        }
        removing.addAll(fresh)
        return fresh
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
                mutableState.update { it.copy(error = userMessage(exception, "Could not load folders")) }
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
    }

    /**
     * Persists the loaded copies of [uids] to the envelope cache — called
     * only after the server confirms a flag write, so an optimistic patch
     * that fails never poisons the cache.
     */
    private fun writeWindowToCache(uids: Set<Long>) {
        val patched =
            mutableState.value.envelopes.values
                .filter { it.id in uids }
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

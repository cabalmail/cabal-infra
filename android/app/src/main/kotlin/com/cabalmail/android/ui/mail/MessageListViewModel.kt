package com.cabalmail.android.ui.mail

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import com.cabalmail.android.AppContainer
import com.cabalmail.kit.models.Envelope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

data class MessageListUiState(
    /** Total messages in the folder; null until the first page lands. */
    val total: Int? = null,
    /** Loaded envelopes keyed by list index (0 = newest). */
    val envelopes: Map<Int, Envelope> = emptyMap(),
    val refreshing: Boolean = false,
    val error: String? = null,
)

/**
 * Index-addressed sliding window over one folder, mirroring the Apple
 * client's virtualization: `/list_messages` (REVERSE ARRIVAL) supplies the
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

    init {
        refresh()
    }

    fun refresh() {
        viewModelScope.launch {
            mutableState.update { it.copy(refreshing = true, error = null) }
            requestedBands.clear()
            try {
                val api = container.requireApi()
                val status = api.folderStatus(folder)
                uidValidity = status.uidValidity
                status.uidValidity?.let { container.envelopeCache.reconcile(folder, it) }
                mutableState.update {
                    MessageListUiState(total = status.messages, refreshing = false)
                }
                ensureBand(0)
            } catch (exception: Exception) {
                mutableState.update {
                    it.copy(refreshing = false, error = exception.message ?: "Could not load $folder")
                }
            }
        }
    }

    /** Called from the list's visible-range effect. */
    fun onVisibleRange(
        firstIndex: Int,
        lastIndex: Int,
    ) {
        (firstIndex / BAND_SIZE..lastIndex / BAND_SIZE).forEach(::ensureBand)
    }

    private fun ensureBand(band: Int) {
        if (band < 0 || !requestedBands.add(band)) {
            return
        }
        viewModelScope.launch {
            try {
                val api = container.requireApi()
                val offset = band * BAND_SIZE
                val page = api.listMessages(folder, offset = offset, limit = BAND_SIZE)
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

    companion object {
        const val BAND_SIZE = 50

        fun factory(
            container: AppContainer,
            folder: String,
        ): ViewModelProvider.Factory =
            viewModelFactory {
                initializer { MessageListViewModel(container, folder) }
            }
    }
}

package com.cabalmail.android.ui.mail

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import com.cabalmail.android.AppContainer
import com.cabalmail.kit.models.Envelope
import com.cabalmail.kit.models.MessageContent
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.serialization.json.Json

data class MessageDetailUiState(
    val envelope: Envelope? = null,
    val content: MessageContent? = null,
    /** Remote content is blocked until the user opts in, per message. */
    val loadRemoteContent: Boolean = false,
    val busy: Boolean = false,
    val error: String? = null,
    /** Set after a dispose/purge so the screen can navigate back. */
    val departed: Boolean = false,
)

class MessageDetailViewModel(
    private val container: AppContainer,
    private val folder: String,
    private val uid: Long,
) : ViewModel() {
    private val mutableState = MutableStateFlow(MessageDetailUiState())
    val state: StateFlow<MessageDetailUiState> = mutableState.asStateFlow()

    private val json = Json { ignoreUnknownKeys = true }

    val isTrashFolder: Boolean = folder == "Trash"

    init {
        load()
    }

    private fun load() {
        viewModelScope.launch {
            mutableState.update { it.copy(busy = true, error = null) }
            try {
                val api = container.requireApi()
                val envelope =
                    container.envelopeCache
                        .read(folder, listOf(uid))[uid]
                        ?: api.listEnvelopes(folder, listOf(uid))[uid]
                val content =
                    container.bodyCache.read(folder, uid)?.let { cached ->
                        runCatching { json.decodeFromString<MessageContent>(cached) }.getOrNull()
                    } ?: api.fetchMessage(folder, uid).also { fetched ->
                        container.bodyCache.write(
                            folder,
                            uid,
                            json.encodeToString(MessageContent.serializer(), fetched),
                        )
                    }
                mutableState.update {
                    it.copy(envelope = envelope, content = content, busy = false)
                }
            } catch (exception: Exception) {
                mutableState.update {
                    it.copy(busy = false, error = exception.message ?: "Could not load message")
                }
            }
        }
    }

    fun allowRemoteContent() {
        mutableState.update { it.copy(loadRemoteContent = true) }
    }

    /** Sets or clears one flag and patches the local envelope copy. */
    fun setFlag(
        flag: String,
        value: Boolean,
    ) {
        viewModelScope.launch {
            try {
                container.requireApi().setFlag(folder, listOf(uid), flag, value)
                mutableState.update { state ->
                    val envelope = state.envelope ?: return@update state
                    val flags =
                        if (value) {
                            (envelope.flags + flag).distinct()
                        } else {
                            envelope.flags.filterNot { it.equals(flag, ignoreCase = true) }
                        }
                    val patched = envelope.copy(flags = flags)
                    state.copy(envelope = patched).also {
                        viewModelScope.launch {
                            container.envelopeCache.write(folder, listOf(patched))
                        }
                    }
                }
            } catch (exception: Exception) {
                mutableState.update { it.copy(error = exception.message ?: "Could not update flag") }
            }
        }
    }

    /** Archive (default dispose), or permanent purge from Trash. */
    fun dispose() {
        viewModelScope.launch {
            mutableState.update { it.copy(busy = true, error = null) }
            try {
                val api = container.requireApi()
                if (isTrashFolder) {
                    api.purgeMessages(folder, listOf(uid))
                } else {
                    api.moveMessages(folder, "Archive", listOf(uid))
                }
                container.envelopeCache.invalidateFolder(folder)
                container.bodyCache.remove(folder, uid)
                mutableState.update { it.copy(busy = false, departed = true) }
            } catch (exception: Exception) {
                mutableState.update {
                    it.copy(busy = false, error = exception.message ?: "Could not move message")
                }
            }
        }
    }

    companion object {
        fun factory(
            container: AppContainer,
            folder: String,
            uid: Long,
        ): ViewModelProvider.Factory =
            viewModelFactory {
                initializer { MessageDetailViewModel(container, folder, uid) }
            }
    }
}

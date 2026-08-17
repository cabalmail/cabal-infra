package com.cabalmail.android.ui.mail

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import com.cabalmail.android.AppContainer
import com.cabalmail.kit.models.Attachment
import com.cabalmail.kit.models.Envelope
import com.cabalmail.kit.models.MessageContent
import com.cabalmail.kit.models.inlineContentIds
import com.cabalmail.kit.models.resolveInlineImages
import io.ktor.client.call.body
import io.ktor.client.request.get
import io.ktor.client.statement.HttpResponse
import io.ktor.http.contentType
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.serialization.json.Json
import java.io.File
import java.util.Base64

/** Original keeps author styling; Reader re-typesets (plan §4.3). */
enum class RenderMode { ORIGINAL, READER }

data class MessageDetailUiState(
    val envelope: Envelope? = null,
    val content: MessageContent? = null,
    /** [MessageContent.bodyHtml] with `cid:` references resolved to data URIs. */
    val resolvedHtml: String? = null,
    val renderMode: RenderMode = RenderMode.ORIGINAL,
    /** Remote content is blocked until the user opts in, per message. */
    val loadRemoteContent: Boolean = false,
    val attachments: List<Attachment> = emptyList(),
    /** Attachment ids with a download in flight. */
    val downloading: Set<Int> = emptySet(),
    /** A downloaded file the screen should hand to ACTION_VIEW, with its MIME type. */
    val openFile: Pair<File, String>? = null,
    /** Move-destination choices; null until requested. */
    val folderChoices: List<String>? = null,
    val busy: Boolean = false,
    val error: String? = null,
    /** Set after a dispose/purge/move so the screen can navigate back. */
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
                container.navCursor.record(
                    folder = folder,
                    uid = uid,
                    messageId = envelope?.messageId?.firstOrNull(),
                )
                resolveInlineImagesAsync(content.bodyHtml)
                if (envelope?.hasAttachments == true) {
                    loadAttachments()
                }
            } catch (exception: Exception) {
                mutableState.update {
                    it.copy(busy = false, error = exception.message ?: "Could not load message")
                }
            }
        }
    }

    /**
     * Replaces `cid:` references with `data:` URIs fetched through
     * `/fetch_inline_image` (presigned URL, fetched with no auth header).
     * Per-image failures leave that reference as-is.
     */
    private fun resolveInlineImagesAsync(html: String) {
        val cids = inlineContentIds(html)
        if (cids.isEmpty()) {
            return
        }
        viewModelScope.launch {
            val api = container.requireApi()
            val resolved = mutableMapOf<String, String>()
            cids.forEach { cid ->
                runCatching {
                    val url = api.fetchInlineImageUrl(folder, uid, cid)
                    val response: HttpResponse = container.httpClient.get(url)
                    val mime = response.contentType()?.toString() ?: "image/png"
                    val bytes: ByteArray = response.body()
                    resolved[cid] = "data:$mime;base64,${Base64.getEncoder().encodeToString(bytes)}"
                }
            }
            if (resolved.isNotEmpty()) {
                mutableState.update { it.copy(resolvedHtml = resolveInlineImages(html, resolved)) }
            }
        }
    }

    private fun loadAttachments() {
        viewModelScope.launch {
            runCatching { container.requireApi().listAttachments(folder, uid) }
                .onSuccess { attachments ->
                    mutableState.update { it.copy(attachments = attachments) }
                }
        }
    }

    fun allowRemoteContent() {
        mutableState.update { it.copy(loadRemoteContent = true) }
    }

    fun toggleRenderMode() {
        mutableState.update {
            it.copy(
                renderMode =
                    when (it.renderMode) {
                        RenderMode.ORIGINAL -> RenderMode.READER
                        RenderMode.READER -> RenderMode.ORIGINAL
                    },
            )
        }
    }

    /**
     * Downloads [attachment] via its presigned URL (no auth header) into
     * the app's attachment cache, then surfaces it for ACTION_VIEW.
     */
    fun downloadAndOpen(attachment: Attachment) {
        if (attachment.id in mutableState.value.downloading) {
            return
        }
        mutableState.update { it.copy(downloading = it.downloading + attachment.id, error = null) }
        viewModelScope.launch {
            try {
                val name = attachment.name ?: "attachment-${attachment.id}"
                val url = container.requireApi().fetchAttachmentUrl(folder, uid, attachment.id, name)
                val bytes: ByteArray = container.httpClient.get(url).body()
                val safeName = name.replace(Regex("""[^A-Za-z0-9._-]"""), "_")
                val file = File(container.attachmentDir, "$uid-${attachment.id}-$safeName")
                file.writeBytes(bytes)
                mutableState.update {
                    it.copy(
                        downloading = it.downloading - attachment.id,
                        openFile = file to attachment.type.ifEmpty { "application/octet-stream" },
                    )
                }
            } catch (exception: Exception) {
                mutableState.update {
                    it.copy(
                        downloading = it.downloading - attachment.id,
                        error = exception.message ?: "Could not download attachment",
                    )
                }
            }
        }
    }

    /** The screen consumed [MessageDetailUiState.openFile]. */
    fun consumeOpenFile() {
        mutableState.update { it.copy(openFile = null) }
    }

    /** Surfaces an open-intent failure (e.g. no viewer app installed). */
    fun reportOpenFailure() {
        mutableState.update { it.copy(openFile = null, error = "No app can open this attachment") }
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
                    api.moveMessages(folder, MessageListViewModel.ARCHIVE_FOLDER, listOf(uid))
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

    /** Moves the open message to [destination] and departs. */
    fun move(destination: String) {
        viewModelScope.launch {
            mutableState.update { it.copy(busy = true, error = null) }
            try {
                container.requireApi().moveMessages(folder, destination, listOf(uid))
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

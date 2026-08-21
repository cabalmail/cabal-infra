package com.cabalmail.android.ui.mail

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import com.cabalmail.android.AppContainer
import com.cabalmail.android.MailEvent
import com.cabalmail.android.userMessage
import com.cabalmail.kit.api.ApiClient
import com.cabalmail.kit.compose.DraftResume
import com.cabalmail.kit.compose.ReplyBuilder
import com.cabalmail.kit.compose.SignatureFormatter
import com.cabalmail.kit.mime.RawHeaders
import com.cabalmail.kit.models.Attachment
import com.cabalmail.kit.models.DraftServerRef
import com.cabalmail.kit.models.Envelope
import com.cabalmail.kit.models.MessageContent
import com.cabalmail.kit.models.inlineContentIds
import com.cabalmail.kit.models.resolveInlineImages
import com.cabalmail.kit.settings.BodyRenderMode
import com.cabalmail.kit.settings.DisposeAction
import com.cabalmail.kit.settings.LoadRemoteContent
import com.cabalmail.kit.settings.MarkAsRead
import io.ktor.client.call.body
import io.ktor.client.request.get
import io.ktor.client.request.header
import io.ktor.client.statement.HttpResponse
import io.ktor.client.statement.bodyAsText
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
    /** A compose seed is staged under this draft id; the screen navigates. */
    val composeDraftId: String? = null,
    /**
     * The staged compose *is* this message (Edit Draft): the reader should
     * be popped, since closing compose replaces the copy it shows.
     */
    val composeReplacesMessage: Boolean = false,
    /** A reply / edit-draft seed is being built. */
    val seedingCompose: Boolean = false,
)

class MessageDetailViewModel(
    internal val container: AppContainer,
    private val folder: String,
    private val uid: Long,
) : ViewModel() {
    private val mutableState = MutableStateFlow(MessageDetailUiState())
    val state: StateFlow<MessageDetailUiState> = mutableState.asStateFlow()

    private val json = Json { ignoreUnknownKeys = true }

    val isTrashFolder: Boolean = folder == "Trash"

    /** For the screen's dispose-intent reconciliation (icon, labels, purge gating). */
    internal val folderName: String = folder

    /** Messages here are the user's own drafts: offer Edit Draft (plan §5.3). */
    val isDraftsFolder: Boolean = folder == DRAFTS_FOLDER

    init {
        // Reading preferences (plan §6.3): the reader's initial render mode
        // and remote-content posture come from settings; a per-message
        // toggle still overrides them for the open message.
        val prefs = container.preferences.preferences.value
        mutableState.update {
            it.copy(
                renderMode =
                    when (prefs.bodyRenderMode) {
                        BodyRenderMode.ORIGINAL -> RenderMode.ORIGINAL
                        BodyRenderMode.READER -> RenderMode.READER
                    },
                loadRemoteContent = prefs.loadRemoteContent == LoadRemoteContent.ALWAYS,
            )
        }
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
                // "Mark as read: On open" (default Manual never touches \Seen).
                if (container.preferences.preferences.value.markAsRead == MarkAsRead.ON_OPEN &&
                    envelope != null &&
                    !envelope.isSeen
                ) {
                    setFlag("\\Seen", true)
                }
                resolveInlineImagesAsync(content.bodyHtml)
                if (envelope?.hasAttachments == true) {
                    loadAttachments()
                }
            } catch (exception: Exception) {
                mutableState.update {
                    it.copy(busy = false, error = userMessage(exception, "Could not load message"))
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
                        error = userMessage(exception, "Could not download attachment"),
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

    /**
     * Sets or clears one flag, patching the local envelope copy and the
     * list (via the event bus) before the server confirms. The server call
     * runs in the app scope so leaving the reader doesn't cancel it, and
     * the envelope cache is only written once the server has agreed.
     */
    fun setFlag(
        flag: String,
        value: Boolean,
    ) {
        val envelope = mutableState.value.envelope ?: return
        val flags =
            if (value) {
                (envelope.flags + flag).distinct()
            } else {
                envelope.flags.filterNot { it.equals(flag, ignoreCase = true) }
            }
        val patched = envelope.copy(flags = flags)
        mutableState.update { it.copy(envelope = patched) }
        container.mailEvents.emit(MailEvent.FlagChanged(folder, setOf(uid), flag, value))
        container.mailEvents.beginWrite()
        container.appScope.launch {
            try {
                container.requireApi().setFlag(folder, listOf(uid), flag, value)
                container.envelopeCache.write(folder, listOf(patched))
            } catch (exception: Exception) {
                mutableState.update { it.copy(error = userMessage(exception, "Could not update flag")) }
                container.mailEvents.emit(MailEvent.Reconcile(folder))
            } finally {
                container.mailEvents.endWrite()
            }
        }
    }

    /**
     * Disposes per the resolved [DisposeIntent]: archive/trash move, restore
     * to the inbox from Archive, or permanent purge from Trash. A split-menu
     * pick passes its [explicitAction]; null follows the preference. Move
     * disposals also mark the message read (archived == read, as on Apple
     * and React), folded into the move call so the flag is set before the
     * UID leaves the source folder; a restore keeps the read state as-is.
     * Ignored while the initial load is still in flight or the message has
     * already departed: a second concurrent MOVE of the same message
     * duplicates it server-side.
     */
    fun dispose(explicitAction: DisposeAction? = null) {
        if (!canDepart()) {
            return
        }
        val intent =
            explicitAction?.let { DisposeIntent.explicit(it, folder) }
                ?: DisposeIntent.standard(
                    container.preferences.preferences.value.disposeAction,
                    folder,
                )
        val markSeen = mutableState.value.envelope?.isSeen != true
        departAfter { api ->
            when (intent) {
                DisposeIntent.Purge -> api.purgeMessages(folder, listOf(uid))
                DisposeIntent.Restore ->
                    api.moveMessages(folder, DisposeIntent.INBOX_FOLDER, listOf(uid))
                is DisposeIntent.Move ->
                    api.moveMessages(folder, intent.destination, listOf(uid), markSeen = markSeen)
            }
        }
    }

    /** Moves the open message to [destination] and departs. */
    fun move(destination: String) {
        if (!canDepart()) {
            return
        }
        departAfter { api -> api.moveMessages(folder, destination, listOf(uid)) }
    }

    /**
     * Whether a move/purge may start: not while the initial load is busy,
     * and never twice — [departAfter] sets `departed` synchronously, so a
     * repeat tap can't queue a second MOVE.
     */
    private fun canDepart(): Boolean {
        val current = mutableState.value
        return !current.busy && !current.departed
    }

    /**
     * Optimistic departure: the reader pops and the list drops the row
     * before the server confirms — success is the overwhelmingly common
     * case. [action] runs in the app scope so it survives this view model
     * being cleared on the way out; the caches are only touched once the
     * server has agreed, and a failure asks the folder's viewers to
     * refetch true state.
     */
    private fun departAfter(action: suspend (ApiClient) -> Unit) {
        mutableState.update { it.copy(departed = true, error = null) }
        container.mailEvents.emit(MailEvent.Removed(folder, setOf(uid)))
        container.mailEvents.beginWrite()
        container.appScope.launch {
            try {
                action(container.requireApi())
                container.envelopeCache.invalidateFolder(folder)
                container.bodyCache.remove(folder, uid)
            } catch (_: Exception) {
                container.mailEvents.emit(MailEvent.Reconcile(folder))
            } finally {
                container.mailEvents.endWrite()
            }
        }
    }

    // -------------------------------------------------------------- compose

    /**
     * Seeds a reply / reply-all / forward draft (plan §5.2) into the local
     * buffer and hands the screen its id. From defaults to the owned address
     * the original was addressed to; threading comes from the fetched body's
     * headers overlaid on the envelope.
     */
    fun startReply(mode: ReplyBuilder.Mode) {
        val envelope = mutableState.value.envelope ?: return
        if (mutableState.value.seedingCompose) {
            return
        }
        mutableState.update { it.copy(seedingCompose = true, error = null) }
        viewModelScope.launch {
            try {
                val repository = container.requireAddressRepository()
                val owned = (repository.addresses.value ?: repository.refresh()).map { it.address }
                val seed =
                    ReplyBuilder.build(
                        envelope = envelope,
                        content = mutableState.value.content,
                        mode = mode,
                        ownedAddresses = owned,
                        sourceFolder = folder,
                    )
                val signature = container.preferences.preferences.value.signature
                val body = SignatureFormatter.seedBody(seed.body, signature)
                val draft = seed.copy(body = body, seedBody = body)
                container.draftStore.save(draft)
                mutableState.update { it.copy(seedingCompose = false, composeDraftId = draft.id) }
            } catch (exception: Exception) {
                mutableState.update {
                    it.copy(seedingCompose = false, error = userMessage(exception, "Could not start reply"))
                }
            }
        }
    }

    /**
     * Edit Draft: seeds compose from this Drafts-folder message. Bcc lives
     * only in the raw headers, so the top of the raw message is fetched
     * (presigned URL, no auth header, ranged) and parsed; the seed points
     * at this UID so the first re-save replaces it and a send discards it.
     */
    fun editDraft() {
        val envelope = mutableState.value.envelope ?: return
        val content = mutableState.value.content ?: return
        if (mutableState.value.seedingCompose) {
            return
        }
        mutableState.update { it.copy(seedingCompose = true, error = null) }
        viewModelScope.launch {
            try {
                val api = container.requireApi()
                val headers =
                    runCatching {
                        val response: HttpResponse =
                            container.httpClient.get(content.messageRawUrl) {
                                header("Range", "bytes=0-${RAW_HEADER_BYTES - 1}")
                            }
                        RawHeaders.parse(response.bodyAsText())
                    }.getOrDefault(emptyList())
                val validity = runCatching { api.folderStatus(folder).uidValidity }.getOrNull()
                val draft =
                    DraftResume.seed(
                        envelope = envelope,
                        content = content,
                        rawHeaders = headers,
                        serverRef = validity?.let { DraftServerRef(uid, it) },
                    )
                container.draftStore.save(draft)
                mutableState.update {
                    it.copy(seedingCompose = false, composeDraftId = draft.id, composeReplacesMessage = true)
                }
            } catch (exception: Exception) {
                mutableState.update {
                    it.copy(seedingCompose = false, error = userMessage(exception, "Could not open draft"))
                }
            }
        }
    }

    /** The screen navigated to the staged compose draft. */
    fun consumeCompose() {
        mutableState.update { it.copy(composeDraftId = null, composeReplacesMessage = false) }
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

    companion object {
        const val DRAFTS_FOLDER = "Drafts"

        /** Enough of a raw message to cover any sane header block. */
        private const val RAW_HEADER_BYTES = 64 * 1024

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

package com.cabalmail.android.ui.compose

import android.net.Uri
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.input.TextFieldValue
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import com.cabalmail.android.AppContainer
import com.cabalmail.kit.CabalmailException
import com.cabalmail.kit.api.ApiClient
import com.cabalmail.kit.compose.ComposePayload
import com.cabalmail.kit.compose.MessageIds
import com.cabalmail.kit.models.Address
import com.cabalmail.kit.models.ComposeIntent
import com.cabalmail.kit.models.Draft
import com.cabalmail.kit.models.DraftAttachment
import com.cabalmail.kit.models.DraftServerRef
import com.cabalmail.kit.models.OutgoingAttachment
import com.cabalmail.kit.models.SendOutcome
import com.cabalmail.kit.models.mailboxAddress
import kotlinx.coroutines.FlowPreview
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.debounce
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.io.File

/** Which recipient row a chip edit targets. */
enum class RecipientField { TO, CC, BCC }

data class ComposeUiState(
    val draft: Draft,
    /** The body as a text field so toolbar actions can act on the selection. */
    val body: TextFieldValue = TextFieldValue(draft.body),
    /** Owned addresses for the From picker; null until loaded. */
    val addresses: List<Address>? = null,
    val showCcBcc: Boolean = draft.cc.isNotEmpty() || draft.bcc.isNotEmpty(),
    val sending: Boolean = false,
    /** A server-side draft save is in flight (60 s sync or close-save). */
    val savingToServer: Boolean = false,
    /** A close-save failed; offer keep-editing vs. close-with-local-copy. */
    val closeSaveFailure: String? = null,
    val importingAttachments: Boolean = false,
    /** Autocomplete matches for the recipient field being typed in. */
    val suggestions: List<String> = emptyList(),
    /** Mail apexes the user may mint on; null until the sheet loads them. */
    val mintableDomains: List<String>? = null,
    val creatingAddress: Boolean = false,
    val newAddressError: String? = null,
    val error: String? = null,
    /** Set once the screen should navigate away. */
    val dismissed: Boolean = false,
) {
    val recipientCount: Int get() = draft.to.size + draft.cc.size + draft.bcc.size

    val canSend: Boolean get() = draft.fromAddress != null && recipientCount > 0 && !sending
}

/**
 * Compose session over one [Draft] in the local buffer (plan §5).
 *
 * - **Local buffer**: every edit is autosaved on a 5 s debounce, and again
 *   on close, so a mid-compose kill is recoverable.
 * - **Server sync**: a 60 s ticker pushes a dirty draft to `/save_draft`
 *   (skipped while empty, without a From, while sending, or while another
 *   save is in flight); close-without-send always pushes. Each save records
 *   the returned `(uidvalidity, uid)` and passes it as `replaces_*` next
 *   time, so the worst failure is a duplicate draft, never a lost one.
 * - **Send** stages attachments through `/upload_url`, mints one
 *   Message-ID per session (kept across retries so `/send`'s dedupe claim
 *   sees the same id), and hands the superseded server draft to
 *   `discard_draft_uid`.
 */
@OptIn(FlowPreview::class)
class ComposeViewModel(
    private val container: AppContainer,
    private val draftId: String,
) : ViewModel() {
    private val mutableState = MutableStateFlow(ComposeUiState(Draft(id = draftId, updatedAt = 0)))
    val state: StateFlow<ComposeUiState> = mutableState.asStateFlow()

    private val edits = MutableSharedFlow<Unit>(extraBufferCapacity = 1)
    private var loaded = false
    private var dirtyForServer = false

    /**
     * Set once the session has ended (sent, closed, discarded). The 5 s
     * local-autosave debounce can fire after the buffer was deleted and
     * would otherwise resurrect a sent draft — which then shows up as an
     * "unsent draft" at the next launch.
     */
    @Volatile
    private var finished = false
    private var suggestionJob: Job? = null

    /**
     * Serializes server saves so a close-save cannot race the 60 s tick:
     * two concurrent replaces of the same UID would leave a duplicate
     * draft (safe, but avoidable).
     */
    private val serverSaveMutex = Mutex()

    /** The Message-ID this session sends with; stable across retries. */
    private var pendingMessageId: String? = null

    private val importer by lazy { AttachmentImporter(container.applicationContext, container.draftStore) }

    init {
        viewModelScope.launch {
            val stored = container.draftStore.load(draftId)
            val draft = stored ?: Draft(id = draftId, updatedAt = System.currentTimeMillis())
            mutableState.update {
                ComposeUiState(
                    draft = draft,
                    body = TextFieldValue(draft.body, TextRange(0)),
                )
            }
            loaded = true
            loadAddresses()
        }
        viewModelScope.launch {
            edits.debounce(LOCAL_AUTOSAVE_MS).collect { persistLocal() }
        }
        viewModelScope.launch {
            while (true) {
                delay(SERVER_AUTOSAVE_MS)
                autosaveToServer()
            }
        }
    }

    // ------------------------------------------------------------ addresses

    private fun loadAddresses() {
        viewModelScope.launch {
            runCatching {
                val repository = container.requireAddressRepository()
                repository.addresses.value ?: repository.refresh()
            }.onSuccess { addresses ->
                mutableState.update { it.copy(addresses = addresses) }
            }.onFailure { exception ->
                mutableState.update { it.copy(error = exception.message ?: "Could not load addresses") }
            }
        }
    }

    fun selectFrom(address: String) {
        edit { it.copy(fromAddress = address) }
    }

    /** Loads the mint-eligible domain list for the "Create new address" sheet. */
    fun loadMintableDomains() {
        if (mutableState.value.mintableDomains != null) {
            return
        }
        viewModelScope.launch {
            val all = container.configService.config.value?.mailDomains.orEmpty()
            val allowed =
                runCatching { container.requireApi().listMyDomains() }
                    .getOrNull()
                    ?.let { permitted -> all.filter { it in permitted } }
                    ?: all // On lookup failure the /new Lambda still gates.
            mutableState.update { it.copy(mintableDomains = allowed) }
        }
    }

    /** Creates `username@subdomain.tld` and selects it as From. */
    fun createAddress(
        username: String,
        subdomain: String,
        tld: String,
        comment: String,
        onCreated: () -> Unit,
    ) {
        mutableState.update { it.copy(creatingAddress = true, newAddressError = null) }
        viewModelScope.launch {
            try {
                val repository = container.requireAddressRepository()
                val created = repository.create(username, subdomain, tld, comment)
                mutableState.update {
                    it.copy(creatingAddress = false, addresses = repository.addresses.value ?: it.addresses)
                }
                selectFrom(created)
                onCreated()
            } catch (exception: Exception) {
                mutableState.update {
                    it.copy(creatingAddress = false, newAddressError = exception.message ?: "Could not create address")
                }
            }
        }
    }

    // ----------------------------------------------------------- recipients

    /**
     * Commits typed recipient text as a chip. Accepts `Name <a@b>` or a bare
     * address; returns false (and surfaces an error) when it is not one.
     */
    fun addRecipient(
        field: RecipientField,
        raw: String,
    ): Boolean {
        val address = mailboxAddress(raw)?.trim()?.trimEnd(',', ';')
        if (address == null || !looksLikeAddress(address)) {
            if (raw.isNotBlank()) {
                mutableState.update { it.copy(error = "Not a valid address: ${raw.trim()}") }
            }
            return false
        }
        edit { draft ->
            when (field) {
                RecipientField.TO -> draft.copy(to = (draft.to + address).distinctBy { it.lowercase() })
                RecipientField.CC -> draft.copy(cc = (draft.cc + address).distinctBy { it.lowercase() })
                RecipientField.BCC -> draft.copy(bcc = (draft.bcc + address).distinctBy { it.lowercase() })
            }
        }
        mutableState.update { it.copy(suggestions = emptyList()) }
        return true
    }

    fun removeRecipient(
        field: RecipientField,
        address: String,
    ) {
        edit { draft ->
            when (field) {
                RecipientField.TO -> draft.copy(to = draft.to - address)
                RecipientField.CC -> draft.copy(cc = draft.cc - address)
                RecipientField.BCC -> draft.copy(bcc = draft.bcc - address)
            }
        }
    }

    fun toggleCcBcc() {
        mutableState.update { it.copy(showCcBcc = !it.showCcBcc) }
    }

    /** Refreshes autocomplete for the text being typed into a recipient field. */
    fun suggestRecipients(query: String) {
        suggestionJob?.cancel()
        if (query.isBlank()) {
            mutableState.update { it.copy(suggestions = emptyList()) }
            return
        }
        suggestionJob =
            viewModelScope.launch {
                val draft = mutableState.value.draft
                val matches = container.recipientHistory.suggest(query, exclude = draft.to + draft.cc + draft.bcc)
                mutableState.update { it.copy(suggestions = matches) }
            }
    }

    // ------------------------------------------------------- subject / body

    fun updateSubject(subject: String) {
        edit { it.copy(subject = subject.replace('\n', ' ').replace('\r', ' ')) }
    }

    fun updateBody(value: TextFieldValue) {
        val changed = value.text != mutableState.value.body.text
        mutableState.update { it.copy(body = value) }
        if (changed) {
            edit { it.copy(body = value.text) }
        }
    }

    /** Applies a Markdown toolbar action to the current body selection. */
    fun applyMarkdown(action: MarkdownAction) {
        val current = mutableState.value.body
        val edited =
            MarkdownEdits.apply(
                action,
                TextSelection(current.text, current.selection.start, current.selection.end),
            )
        updateBody(TextFieldValue(edited.text, TextRange(edited.start, edited.end)))
    }

    // ---------------------------------------------------------- attachments

    fun addAttachments(uris: List<Uri>) {
        if (uris.isEmpty()) {
            return
        }
        mutableState.update { it.copy(importingAttachments = true) }
        viewModelScope.launch {
            val imported = uris.mapNotNull { uri -> importer.import(draftId, uri) }
            val skipped = uris.size - imported.size
            mutableState.update { it.copy(importingAttachments = false) }
            if (imported.isNotEmpty()) {
                edit { it.copy(attachments = it.attachments + imported) }
            }
            if (skipped > 0) {
                mutableState.update { it.copy(error = "Could not attach $skipped file(s)") }
            }
        }
    }

    fun removeAttachment(attachment: DraftAttachment) {
        edit { it.copy(attachments = it.attachments - attachment) }
        viewModelScope.launch { runCatching { File(attachment.path).delete() } }
    }

    // ---------------------------------------------------------- persistence

    /** Applies an edit to the draft and schedules both autosaves. */
    private fun edit(transform: (Draft) -> Draft) {
        mutableState.update { state ->
            state.copy(draft = transform(state.draft).copy(updatedAt = System.currentTimeMillis()))
        }
        dirtyForServer = true
        edits.tryEmit(Unit)
    }

    private suspend fun persistLocal() {
        if (!loaded || finished) {
            return
        }
        val draft = mutableState.value.draft
        if (draft.isEmpty && draft.serverRef == null) {
            // Nothing worth a file yet; the store never keeps blank drafts.
            container.draftStore.delete(draftId)
            return
        }
        container.draftStore.save(draft)
    }

    /**
     * The 60 s sync tick. Silent on failure by design: the local autosave
     * is the durability story and the next tick (or close) retries.
     */
    private suspend fun autosaveToServer() {
        val current = mutableState.value
        if (!dirtyForServer || current.sending || current.savingToServer) {
            return
        }
        val draft = current.draft
        val from = draft.fromAddress ?: return
        if (draft.isEmpty) {
            return
        }
        dirtyForServer = false
        runCatching { pushDraftToServer(draft, from) }.onFailure { dirtyForServer = true }
    }

    /**
     * One `/save_draft` round trip: stage attachments, replace the prior
     * server copy, adopt the returned coordinates. Throws on failure.
     */
    private suspend fun pushDraftToServer(
        draft: Draft,
        from: String,
    ): DraftServerRef? =
        serverSaveMutex.withLock {
            // Re-read the coordinates: a save that just finished ahead of
            // us may have moved the server copy.
            val current = mutableState.value.draft
            pushDraftToServerLocked(draft.withServerRef(current.serverRef), from)
        }

    private suspend fun pushDraftToServerLocked(
        draft: Draft,
        from: String,
    ): DraftServerRef? {
        mutableState.update { it.copy(savingToServer = true) }
        try {
            val api = container.requireApi()
            val staged = stageAttachments(api, draft.attachments)
            val result =
                api.saveDraft(
                    ComposePayload.build(draft, from, staged = staged),
                    replacesUid = draft.serverUid,
                    replacesUidValidity = draft.serverUidValidity,
                )
            val uid = result.uid
            val validity = result.uidvalidity
            val ref = if (uid != null && validity != null) DraftServerRef(uid, validity) else null
            if (ref != null) {
                mutableState.update { it.copy(draft = it.draft.withServerRef(ref)) }
                container.draftStore.save(mutableState.value.draft)
            }
            return ref
        } finally {
            mutableState.update { it.copy(savingToServer = false) }
        }
    }

    private suspend fun stageAttachments(
        api: ApiClient,
        attachments: List<DraftAttachment>,
    ): List<OutgoingAttachment> {
        if (attachments.isEmpty()) {
            return emptyList()
        }
        val grants = api.requestUploadUrls(attachments.map { it.filename to it.mimeType })
        if (grants.size != attachments.size) {
            throw CabalmailException.ProtocolError("Upload grant count mismatch")
        }
        return attachments.zip(grants).map { (attachment, grant) ->
            val bytes = File(attachment.path).readBytes()
            api.uploadToGrant(grant.url, attachment.mimeType, bytes)
            OutgoingAttachment(filename = attachment.filename, mimeType = attachment.mimeType, s3Key = grant.key)
        }
    }

    // ------------------------------------------------------------- lifecycle

    /**
     * Send (plan §5.1). On success the local buffer goes away, the reply
     * source is marked `\Answered`, recipients feed autocomplete, and the
     * screen dismisses. On failure the screen stays with a snackbar.
     */
    fun send() {
        val current = mutableState.value
        val draft = current.draft
        val from = draft.fromAddress ?: return
        if (!current.canSend) {
            return
        }
        mutableState.update { it.copy(sending = true, error = null) }
        viewModelScope.launch {
            try {
                // Wait for any in-flight server save so the discard names
                // the copy that save produced, not a stale one.
                val outcome =
                    serverSaveMutex.withLock {
                        val api = container.requireApi()
                        val staged = stageAttachments(api, draft.attachments)
                        val host = from.substringAfter('@', missingDelimiterValue = "cabalmail")
                        val messageId = pendingMessageId ?: MessageIds.generate(host).also { pendingMessageId = it }
                        val fields = ComposePayload.build(draft, from, messageId = messageId, staged = staged)
                        val ref = mutableState.value.draft.serverRef
                        api.send(fields, ref?.uid, ref?.uidValidity)
                    }
                when (outcome) {
                    is SendOutcome.Submitted -> {
                        finished = true
                        markAnswered(draft)
                        container.recipientHistory.record(draft.to + draft.cc + draft.bcc)
                        container.draftStore.delete(draftId)
                        mutableState.update { it.copy(sending = false, dismissed = true) }
                    }
                    SendOutcome.DuplicateInFlight ->
                        mutableState.update {
                            it.copy(sending = false, error = "An earlier send is still in progress; try again shortly")
                        }
                }
            } catch (exception: Exception) {
                mutableState.update {
                    it.copy(sending = false, error = exception.message ?: "Could not send message")
                }
            }
        }
    }

    /** Best-effort `\Answered` on the replied-to message. */
    private suspend fun markAnswered(draft: Draft) {
        val folder = draft.replySourceFolder ?: return
        val uid = draft.replySourceUid ?: return
        if (draft.composeIntent != ComposeIntent.REPLY && draft.composeIntent != ComposeIntent.REPLY_ALL) {
            return
        }
        runCatching {
            container.requireApi().setFlag(folder, listOf(uid), "\\Answered", true)
            container.envelopeCache.read(folder, listOf(uid))[uid]?.let { envelope ->
                container.envelopeCache.write(
                    folder,
                    listOf(envelope.copy(flags = (envelope.flags + "\\Answered").distinct())),
                )
            }
        }
    }

    /**
     * Close-without-send (plan §5.3). Empty drafts are dropped (and their
     * server copy discarded); a draft with content but no From cannot be
     * saved server-side, so the user is asked to pick one or discard;
     * otherwise the draft is pushed and, on success, the local buffer is
     * removed because the server copy is now canonical.
     */
    fun requestClose() {
        val current = mutableState.value
        if (current.sending) {
            return
        }
        val draft = current.draft
        val from = draft.fromAddress
        viewModelScope.launch {
            persistLocal()
            when {
                draft.isEmpty -> {
                    finished = true
                    discardServerCopy(draft.serverRef)
                    container.draftStore.delete(draftId)
                    mutableState.update { it.copy(dismissed = true) }
                }
                from == null ->
                    mutableState.update {
                        it.copy(error = "Choose a From address to save this draft, or discard it")
                    }
                else -> {
                    try {
                        pushDraftToServer(draft, from)
                        finished = true
                        container.draftStore.delete(draftId)
                        mutableState.update { it.copy(dismissed = true) }
                    } catch (exception: Exception) {
                        mutableState.update {
                            it.copy(closeSaveFailure = exception.message ?: "Could not save draft")
                        }
                    }
                }
            }
        }
    }

    /** After a failed close-save: keep editing. */
    fun keepEditing() {
        mutableState.update { it.copy(closeSaveFailure = null) }
    }

    /** After a failed close-save: leave, keeping the local copy for later. */
    fun closeKeepingLocalCopy() {
        viewModelScope.launch {
            persistLocal()
            finished = true
            mutableState.update { it.copy(closeSaveFailure = null, dismissed = true) }
        }
    }

    /** Deletes the local buffer and the server copy (if any), then dismisses. */
    fun discard() {
        val ref = mutableState.value.draft.serverRef
        finished = true
        viewModelScope.launch {
            container.draftStore.delete(draftId)
            mutableState.update { it.copy(dismissed = true) }
        }
        discardServerCopy(ref)
    }

    private fun discardServerCopy(ref: DraftServerRef?) {
        ref ?: return
        val from = mutableState.value.draft.fromAddress ?: return
        // Outlives the screen: fire on the app scope, best effort.
        container.appScope.launch {
            runCatching {
                container.requireApi().saveDraft(
                    ComposePayload.build(mutableState.value.draft, from),
                    replacesUid = ref.uid,
                    replacesUidValidity = ref.uidValidity,
                    discard = true,
                )
            }
        }
    }

    /** The screen showed the transient error. */
    fun clearError() {
        mutableState.update { it.copy(error = null) }
    }

    /** Flush the local buffer when the screen stops (home button, etc.). */
    fun onStop() {
        viewModelScope.launch { persistLocal() }
    }

    override fun onCleared() {
        // The debounce coroutine dies with the scope; do a last synchronous
        // best-effort flush so an edit inside the 5 s window is not lost.
        val draft = mutableState.value.draft
        if (loaded && !finished && !mutableState.value.dismissed && !(draft.isEmpty && draft.serverRef == null)) {
            container.appScope.launch { container.draftStore.save(draft) }
        }
    }

    private fun looksLikeAddress(address: String): Boolean {
        val at = address.indexOf('@')
        return at > 0 && at < address.length - 1 && !address.contains(' ') && address.substring(at + 1).contains('.')
    }

    companion object {
        const val LOCAL_AUTOSAVE_MS = 5_000L

        /** Do not shorten: server saves are IMAP writes on a single-task tier. */
        const val SERVER_AUTOSAVE_MS = 60_000L

        fun factory(
            container: AppContainer,
            draftId: String,
        ): ViewModelProvider.Factory =
            viewModelFactory {
                initializer { ComposeViewModel(container, draftId) }
            }
    }
}

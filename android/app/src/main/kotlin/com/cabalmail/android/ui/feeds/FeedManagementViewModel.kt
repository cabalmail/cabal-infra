package com.cabalmail.android.ui.feeds

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import com.cabalmail.android.AppContainer
import com.cabalmail.kit.models.RssFolder
import com.cabalmail.kit.models.RssFolderUpdate
import com.cabalmail.kit.models.RssItemScope
import com.cabalmail.kit.models.RssOpmlImportResult
import com.cabalmail.kit.models.RssSubscription
import com.cabalmail.kit.models.RssSubscriptionUpdate
import com.cabalmail.kit.rss.RssClient
import com.cabalmail.kit.rss.RssStore
import com.cabalmail.kit.rss.RssSyncEngine
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import java.io.File

/** Which management sheet is up. */
sealed interface FeedSheet {
    data class Subscribe(
        val folderId: String,
    ) : FeedSheet

    /** [editing] null = create under [parentId]. */
    data class Folder(
        val editing: RssFolder?,
        val parentId: String,
    ) : FeedSheet

    data class Settings(
        val subscription: RssSubscription,
    ) : FeedSheet
}

/** A destructive or sweeping action awaiting the user's confirmation. */
sealed interface FeedConfirm {
    data class Unsubscribe(
        val subscription: RssSubscription,
    ) : FeedConfirm

    data class DeleteFolder(
        val folder: RssFolder,
    ) : FeedConfirm

    data class MarkAllRead(
        val scope: RssItemScope,
        val title: String,
    ) : FeedConfirm
}

/** One-shot outcomes the screen turns into words (wording stays in the screen, so the model unit-tests). */
sealed interface FeedNotice {
    data class Subscribed(
        val subscription: RssSubscription,
        val existing: Boolean,
    ) : FeedNotice

    data object Unsubscribed : FeedNotice

    data class OpmlImported(
        val result: RssOpmlImportResult,
    ) : FeedNotice

    data class OpmlExported(
        val file: File,
    ) : FeedNotice
}

data class FeedManagementUiState(
    val busy: Boolean = false,
    val error: String? = null,
    val sheet: FeedSheet? = null,
    val confirm: FeedConfirm? = null,
    val notice: FeedNotice? = null,
    /** True while the screen should raise the OPML document picker. */
    val importRequested: Boolean = false,
    val importFolderId: String? = null,
    /** The folders the pickers offer, read from the store when a sheet opens. */
    val folders: List<RssFolder> = emptyList(),
)

/**
 * Feed management (rss plan, phase 6c), the Apple `FeedManagementViewModel`:
 * subscribe, unsubscribe, per-feed settings, folders, mark-all-read for a
 * scope, and OPML. Server first, then the store: a subscribe or update
 * writes the server's row back; everything that changes the catalog's
 * shape (unsubscribe, folders, import) re-pulls the catalog, which also
 * reports the departed subscriptions' web profiles to drop. Every change
 * posts on the bus so the tree and the lists follow. Narrow collaborators
 * rather than the container, so it unit-tests against the kit's in-memory
 * store.
 */
class FeedManagementViewModel(
    private val rss: suspend () -> RssClient,
    private val store: RssStore,
    private val engine: suspend () -> RssSyncEngine,
    private val events: FeedEventBus,
    private val exportDir: File,
    private val onDroppedProfiles: (List<String>) -> Unit = {},
    /** Where the export file is written; tests pass the test dispatcher. */
    private val io: CoroutineDispatcher = Dispatchers.IO,
) : ViewModel() {
    private val mutableState = MutableStateFlow(FeedManagementUiState())
    val state: StateFlow<FeedManagementUiState> = mutableState.asStateFlow()

    // ------------------------------------------------------------ presenting

    fun openSubscribe(folderId: String = "") = openSheet(FeedSheet.Subscribe(folderId))

    fun openNewFolder(parentId: String = "") = openSheet(FeedSheet.Folder(editing = null, parentId = parentId))

    fun openEditFolder(folder: RssFolder) =
        openSheet(FeedSheet.Folder(editing = folder, parentId = folder.parentFolderId))

    fun openSettings(subscription: RssSubscription) = openSheet(FeedSheet.Settings(subscription))

    /** Edit a folder by id, reading it from the store (the tree row carries only the id). */
    fun openEditFolderById(folderId: String) {
        viewModelScope.launch { store.folder(folderId)?.let(::openEditFolder) }
    }

    fun confirmDeleteFolderById(folderId: String) {
        viewModelScope.launch { store.folder(folderId)?.let { confirm(FeedConfirm.DeleteFolder(it)) } }
    }

    private fun openSheet(sheet: FeedSheet) {
        mutableState.update { it.copy(sheet = sheet, error = null) }
        viewModelScope.launch {
            val folders = runCatching { store.folders() }.getOrDefault(emptyList())
            mutableState.update { it.copy(folders = folders) }
        }
    }

    fun dismissSheet() = mutableState.update { it.copy(sheet = null, error = null) }

    fun confirm(confirm: FeedConfirm) = mutableState.update { it.copy(confirm = confirm) }

    fun dismissConfirm() = mutableState.update { it.copy(confirm = null) }

    fun clearNotice() = mutableState.update { it.copy(notice = null) }

    fun clearError() = mutableState.update { it.copy(error = null) }

    /** Asks the screen to raise the document picker; the picked file comes back through [importOpml]. */
    fun requestImport(folderId: String? = null) =
        mutableState.update { it.copy(importRequested = true, importFolderId = folderId) }

    fun consumeImportRequest() = mutableState.update { it.copy(importRequested = false) }

    // ------------------------------------------------------------ operations

    /** Subscribes, stores the server's row, and pulls a new feed's first page. */
    fun subscribe(
        url: String,
        folderId: String,
    ) = busy("Could not subscribe") {
        val result = rss().subscribe(url, folderId.ifEmpty { null })
        store.upsertSubscription(result.subscription)
        events.post(FeedEvent.CatalogChanged)
        if (!result.existing) {
            runCatching { engine().syncItems(result.subscription) }
            events.post(FeedEvent.Changed)
        }
        mutableState.update {
            it.copy(sheet = null, notice = FeedNotice.Subscribed(result.subscription, result.existing))
        }
    }

    fun unsubscribe(subscription: RssSubscription) =
        busy("Could not unsubscribe") {
            rss().unsubscribe(subscription.subscriptionId)
            refreshCatalog()
            mutableState.update { it.copy(sheet = null, confirm = null, notice = FeedNotice.Unsubscribed) }
        }

    fun updateSubscription(
        subscription: RssSubscription,
        update: RssSubscriptionUpdate,
    ) = busy("Could not save the feed settings") {
        val updated = rss().updateSubscription(subscription.subscriptionId, update)
        store.upsertSubscription(updated)
        events.post(FeedEvent.CatalogChanged)
        mutableState.update { it.copy(sheet = null) }
    }

    fun createFolder(
        name: String,
        parentId: String,
    ) = busy("Could not create the folder") {
        rss().newRssFolder(name.trim(), parentId.ifEmpty { null })
        refreshCatalog()
        mutableState.update { it.copy(sheet = null) }
    }

    fun updateFolder(
        folder: RssFolder,
        update: RssFolderUpdate,
    ) = busy("Could not save the folder") {
        rss().updateRssFolder(folder.folderId, update)
        refreshCatalog()
        mutableState.update { it.copy(sheet = null) }
    }

    /** The server moves the folder's contents to its parent; nothing is unsubscribed. */
    fun deleteFolder(folder: RssFolder) =
        busy("Could not delete the folder") {
            rss().deleteRssFolder(folder.folderId)
            refreshCatalog()
            mutableState.update { it.copy(confirm = null) }
        }

    /** Store first (offline-safe), through the engine, for every subscription in scope. */
    fun markAllRead(scope: RssItemScope) {
        mutableState.update { it.copy(confirm = null) }
        viewModelScope.launch {
            try {
                val engine = engine()
                val feedIds = store.feedIds(scope).toSet()
                store.subscriptions().filter { it.feedId in feedIds }.forEach { engine.markAllRead(it.subscriptionId) }
                events.post(FeedEvent.Changed)
            } catch (exception: Exception) {
                if (exception is CancellationException) throw exception
                mutableState.update { it.copy(error = feedUserMessage(exception, "Could not mark all read")) }
            }
        }
    }

    fun importOpml(
        opml: String,
        folderId: String?,
    ) = busy("Could not import the OPML file") {
        val result = rss().importOpml(opml, folderId)
        refreshCatalog()
        if (result.created > 0) {
            viewModelScope.launch {
                runCatching { engine().syncAll() }
                events.post(FeedEvent.Changed)
            }
        }
        mutableState.update { it.copy(notice = FeedNotice.OpmlImported(result)) }
    }

    fun exportOpml() =
        busy("Could not export the feeds") {
            val export = rss().exportOpml()
            val file = FeedOpmlFiles.writeExport(exportDir, export.filename, export.opml, io)
            mutableState.update { it.copy(notice = FeedNotice.OpmlExported(file)) }
        }

    private suspend fun refreshCatalog() {
        val diff = engine().refreshCatalog()
        if (diff.removedDataStoreUuids.isNotEmpty()) onDroppedProfiles(diff.removedDataStoreUuids)
        events.post(FeedEvent.CatalogChanged)
    }

    /** One operation at a time; the error lands in state and the sheet stays open. */
    private fun busy(
        failure: String,
        block: suspend () -> Unit,
    ) {
        if (mutableState.value.busy) return
        mutableState.update { it.copy(busy = true, error = null) }
        viewModelScope.launch {
            try {
                block()
            } catch (exception: Exception) {
                if (exception is CancellationException) throw exception
                mutableState.update { it.copy(error = feedUserMessage(exception, failure)) }
            } finally {
                mutableState.update { it.copy(busy = false) }
            }
        }
    }

    companion object {
        fun factory(container: AppContainer): ViewModelProvider.Factory =
            viewModelFactory {
                initializer {
                    FeedManagementViewModel(
                        rss = { container.requireApi() },
                        store = container.rssStore,
                        engine = { container.requireRssSync() },
                        events = container.feedEvents,
                        exportDir = container.attachmentDir,
                        onDroppedProfiles = { FeedWebProfiles.drop(container.applicationContext, it) },
                    )
                }
            }
    }
}

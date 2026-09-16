package com.cabalmail.android.navigation

import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.filterNotNull
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import java.io.File

/** The section the app was last in. */
@Serializable
enum class ResumeSection { MAIL, FEEDS }

/**
 * What this install last had on screen — the Android `ResumeSession`
 * (resume-session plan, Phase B). Mail and feed positions are kept
 * independently so a user who switches sections and back within one
 * relaunch gets both restored. Per install, never synced; the server
 * `nav_state` cursor is the cross-device signal and stays separate.
 *
 * `feedScope` is an `RssItemScope.token`; `feedItemId` is `RssItem.id`
 * (`feedId#sortKey`) — the identities `FeedRoutes` already routes on.
 */
@Serializable
data class ResumeSession(
    val section: ResumeSection = ResumeSection.MAIL,
    val folder: String? = null,
    val uid: Long? = null,
    val messageId: String? = null,
    val feedScope: String? = null,
    val feedItemId: String? = null,
    val savedAt: Long = 0L,
) {
    val hasMessage: Boolean get() = uid != null || messageId != null
}

/**
 * Persists the [ResumeSession] as one JSON file and serves two views of it:
 * the **launch snapshot** (what the file said when the process started,
 * frozen — the record a first landing restores from) and the **live**
 * record (mutated by every recording call — what a rebuilt navigation host
 * mid-process must restore from instead; the Apple lesson from #1555).
 *
 * Recording calls are not suspending: they queue onto a single actor so a
 * burst from view-model inits and clears applies in call order, then a
 * short debounce coalesces the writes. Clears are guarded by identity
 * (`recordNoMessage(folder, uid)` only clears if that message is still the
 * recorded one), because on a wide window the next item's view model is
 * created before the previous one's is cleared.
 */
class ResumeSessionStore(
    private val file: File,
    scope: CoroutineScope,
    private val io: CoroutineDispatcher = Dispatchers.IO,
    private val debounceMs: Long = WRITE_DEBOUNCE_MS,
    private val now: () -> Long = System::currentTimeMillis,
) {
    private val json = Json { ignoreUnknownKeys = true }
    private val loadMutex = Mutex()
    private var loaded: ResumeSession? = null
    private var snapshot: ResumeSession? = null
    private var snapshotTaken = false
    private val ops = Channel<(ResumeSession) -> ResumeSession>(Channel.UNLIMITED)
    private val pending = MutableStateFlow<ResumeSession?>(null)

    private val actor =
        scope.launch {
            for (op in ops) {
                val next = op(live())
                loaded = next
                pending.value = next
            }
        }
    private val writer =
        scope.launch {
            pending.filterNotNull().collectLatest { session ->
                delay(debounceMs)
                persist(session)
            }
        }

    /** Stops the actor and writer (tests; the app keeps one store for the process). */
    fun close() {
        actor.cancel()
        writer.cancel()
    }

    /**
     * The record as it was when the process started; the same value on every
     * call, so a navigation host that is rebuilt (rotation restores the back
     * stack instead, but a size-class flip may not) compares against a
     * stable baseline. The first call reads the file.
     */
    suspend fun launchSnapshot(): ResumeSession? {
        ensureLoaded()
        return snapshot
    }

    /** The live record — where the user is now. */
    suspend fun current(): ResumeSession = live()

    fun recordFolder(folder: String) =
        enqueue {
            it.copy(section = ResumeSection.MAIL, folder = folder, uid = null, messageId = null)
        }

    fun recordMessage(
        folder: String,
        uid: Long,
        messageId: String?,
    ) = enqueue {
        it.copy(section = ResumeSection.MAIL, folder = folder, uid = uid, messageId = messageId)
    }

    /** Back to the list: clears the message only if it is still the recorded one. */
    fun recordNoMessage(
        folder: String,
        uid: Long,
    ) = enqueue {
        if (it.folder == folder && it.uid == uid) it.copy(uid = null, messageId = null) else it
    }

    /**
     * The feed list scope changed. A scope puts the session in the feeds
     * section; clearing it (back to the feed tree) keeps the section.
     */
    fun recordFeedScope(scopeToken: String?) =
        enqueue {
            it.copy(
                section = if (scopeToken != null) ResumeSection.FEEDS else it.section,
                feedScope = scopeToken,
                feedItemId = null,
            )
        }

    fun recordFeedItem(itemId: String) =
        enqueue {
            it.copy(section = ResumeSection.FEEDS, feedItemId = itemId)
        }

    /** The reader closed: clears the item only if it is still the recorded one. */
    fun recordNoFeedItem(itemId: String) =
        enqueue {
            if (it.feedItemId == itemId) it.copy(feedItemId = null) else it
        }

    /** The top-level destination changed. Only the section moves. */
    fun noteSection(section: ResumeSection) =
        enqueue {
            if (it.section == section) it else it.copy(section = section)
        }

    /** Sign-out: forget everything this install remembered for the account. */
    suspend fun clear() {
        loadMutex.withLock {
            loaded = ResumeSession()
            snapshot = null
            snapshotTaken = true
            pending.value = null
            withContext(io) { file.delete() }
        }
    }

    private fun enqueue(transform: (ResumeSession) -> ResumeSession) {
        ops.trySend { session -> transform(session).copy(savedAt = now()) }
    }

    private suspend fun live(): ResumeSession {
        ensureLoaded()
        return loaded ?: ResumeSession()
    }

    private suspend fun ensureLoaded() {
        if (snapshotTaken) return
        loadMutex.withLock {
            if (snapshotTaken) return
            val read =
                withContext(io) {
                    runCatching { json.decodeFromString<ResumeSession>(file.readText()) }.getOrNull()
                }
            snapshot = read
            if (loaded == null) loaded = read
            snapshotTaken = true
        }
    }

    private suspend fun persist(session: ResumeSession) =
        withContext(io) {
            runCatching {
                file.parentFile?.mkdirs()
                val tmp = File(file.parentFile, file.name + ".tmp")
                tmp.writeText(json.encodeToString(ResumeSession.serializer(), session))
                tmp.renameTo(file)
            }
        }

    companion object {
        const val WRITE_DEBOUNCE_MS = 300L
    }
}

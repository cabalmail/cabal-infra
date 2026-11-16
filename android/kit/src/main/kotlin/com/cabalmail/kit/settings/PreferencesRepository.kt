package com.cabalmail.kit.settings

import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.MutablePreferences
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.booleanPreferencesKey
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.core.stringSetPreferencesKey
import com.cabalmail.kit.CabalmailException
import com.cabalmail.kit.api.ApiClient
import com.cabalmail.kit.models.PreferencesSaveResult
import com.cabalmail.kit.models.RssItemFilter
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.FlowPreview
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.debounce
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.Json
import java.security.MessageDigest
import com.cabalmail.kit.models.Preferences as RemotePreferences

/**
 * The preference store (plan §6.3): a DataStore-backed local cache that is
 * the source of truth for the UI, plus the server sync that keeps the
 * shared subset consistent with the web and Apple clients. The server's
 * side of the contract is `docs/settings-sync.md`.
 *
 * **A device sends only what was changed on it, and says which version of
 * the account's row it was built on.** A [SettingsSyncLedger], kept in the
 * store beside the values, holds the row as this device last saw it and
 * the keys a local [update] has changed that the server has not taken.
 *
 * - **A pull** ([refreshFromServer], at sign-in and each launch) takes the
 *   row's value for every key that is not owed and leaves the owed ones,
 *   then sends what is still owed.
 * - **A push** (a short debounce after each [update]) carries the owed
 *   keys only, never the whole payload, with the row's version. Nothing
 *   is sent before this device has read the row: a device new to the
 *   account holds defaults, not the account's settings (#2452).
 * - **A push built on an older row is refused** (a 409 carrying the row).
 *   The row is taken as a pull is, the flag list merged with this
 *   device's when both changed it, and the push goes again (#2464).
 * - **A push that fails stays owed**, across relaunches, and goes again at
 *   the next [update] or launch. One the server refuses (a 400) is not
 *   sent again in this run until one of its values changes.
 * - **The synced settings belong to one account.** When another account
 *   signs in on this device they are put back to their defaults before
 *   anything is read or sent, so one account's settings never reach the
 *   next account's row (#2471).
 * - Local-only fields (dynamic color, default sort) never leave the device.
 * - The typed values (a flag's name, the signature, the display name) are
 *   held to what the server takes ([ServerTextRules]) on every write and
 *   every read of the store, so none of them can make the server refuse
 *   the request that carries them (#2453).
 *
 * @param account Names the signed-in account (any stable text, such as
 *   the username and the control domain), or null while nobody is signed
 *   in. Only a hash of it is stored.
 */
@OptIn(FlowPreview::class)
class PreferencesRepository(
    private val dataStore: DataStore<Preferences>,
    private val scope: CoroutineScope,
    private val account: suspend () -> String? = { null },
    private val api: suspend () -> ApiClient,
) {
    private object Keys {
        val DISPLAY_NAME = stringPreferencesKey("display_name")
        val ACCENT = stringPreferencesKey("accent")
        val DENSITY = stringPreferencesKey("density")
        val THEME = stringPreferencesKey("theme")
        val MARK_AS_READ = stringPreferencesKey("mark_as_read")
        val LOAD_REMOTE_CONTENT = stringPreferencesKey("load_remote_content")
        val BODY_RENDER_MODE = stringPreferencesKey("body_render_mode")
        val FOLDER_COUNT_DISPLAY = stringPreferencesKey("folder_count_display")
        val DISPOSE_ACTION = stringPreferencesKey("dispose_action")
        val DISPOSE_ADVANCE = stringPreferencesKey("dispose_advance")
        val DEFAULT_FROM_ADDRESS = stringPreferencesKey("default_from_address")
        val SIGNATURE = stringPreferencesKey("signature")
        val FLAG_PALETTE = stringPreferencesKey("flag_palette")
        val FLAG_PALETTE_SYNCABLE = booleanPreferencesKey("flag_palette_syncable")
        val MAIL_FOLDER_FILTERS = stringPreferencesKey("mail_folder_filters")
        val RSS_MARK_AS_READ = stringPreferencesKey("rss_mark_as_read")
        val FEEDS_ALL_FILTER = stringPreferencesKey("feeds_all_filter")
        val SWIPE_LEADING = stringPreferencesKey("swipe_leading")
        val SWIPE_TRAILING = stringPreferencesKey("swipe_trailing")
        val RSS_SWIPE_LEADING = stringPreferencesKey("rss_swipe_leading")
        val RSS_SWIPE_TRAILING = stringPreferencesKey("rss_swipe_trailing")
        val DYNAMIC_COLOR = booleanPreferencesKey("dynamic_color")
        val NOTIFICATIONS_ENABLED = booleanPreferencesKey("notifications_enabled")
        val PUSH_FOLDERS = stringSetPreferencesKey("push_folders")
        val DEFAULT_SORT = stringPreferencesKey("default_sort")
        val DEFAULT_SORT_DESCENDING = booleanPreferencesKey("default_sort_descending")
        val FOLDER_FILTER_SUBSCRIBED = booleanPreferencesKey("folder_filter_subscribed")
        val FOLDER_FILTER_UNREAD = booleanPreferencesKey("folder_filter_unread")
        val FEED_COLLAPSED_FOLDERS = stringSetPreferencesKey("feed_collapsed_folders")
        val FEED_FILTER_UNREAD = booleanPreferencesKey("feed_filter_unread")

        /** Not a setting: the [SettingsSyncLedger] as JSON. */
        val SYNC_LEDGER = stringPreferencesKey("sync_ledger")

        /** Not a setting: a hash of the account the synced settings are. */
        val SYNC_ACCOUNT = stringPreferencesKey("sync_account")
    }

    private val pushRequests = MutableSharedFlow<Unit>(extraBufferCapacity = 1)

    /** One sync at a time: a pull and a push each read the ledger and write it back. */
    private val syncing = Mutex()

    /** The changes the server last refused (a 400), for this run only. */
    private var refused: Map<String, String>? = null

    private val ledgerJson = Json { ignoreUnknownKeys = true }

    /** Current preferences; defaults until DataStore has been read. */
    val preferences: StateFlow<AppPreferences> =
        dataStore.data
            .map(::decode)
            .stateIn(scope, SharingStarted.Eagerly, AppPreferences())

    init {
        scope.launch {
            pushRequests.debounce(PUSH_DEBOUNCE_MS).collect { pushToServer() }
        }
    }

    /** The persisted preferences, read now (not the eagerly-shared snapshot). */
    suspend fun current(): AppPreferences = decode(dataStore.data.first())

    /** Whether a local change is still waiting for the server to take it. */
    suspend fun hasUnsentChanges(): Boolean = ledger(dataStore.data.first()).hasUnsent

    /**
     * Applies a local change, records which synced keys it changed, and
     * schedules the server push.
     */
    suspend fun update(transform: (AppPreferences) -> AppPreferences) {
        ensureAccount()
        dataStore.edit { store ->
            val before = decode(store)
            val next =
                accepted(transform(before)).let {
                    // A palette that has existed must keep syncing even once
                    // emptied, or a deletion could never reach the server.
                    if (it.flagPalette.isNotEmpty()) it.copy(flagPaletteSyncable = true) else it
                }
            encode(store, next)
            val was = PreferencesWire.toValues(before)
            val now = PreferencesWire.toValues(next)
            val changed = now.filter { (key, value) -> was[key] != value }.keys
            if (changed.isNotEmpty()) store.writeLedger(ledger(store).edited(changed, now))
        }
        pushRequests.tryEmit(Unit)
    }

    /**
     * Pulls the account's row, applies it to every setting this device
     * does not owe the server, then sends what it does owe. A failure
     * leaves the cache and what is owed as they were; the next launch or
     * [update] tries again.
     */
    suspend fun refreshFromServer() =
        syncing.withLock {
            ensureAccount()
            pull()
            push()
        }

    /** Sends what is owed now. The debounce calls it; internal so a test can, without waiting. */
    internal suspend fun pushToServer() =
        syncing.withLock {
            ensureAccount()
            push()
        }

    /**
     * Fetches the account's row and takes it. True when the server
     * answered.
     */
    private suspend fun pull(): Boolean {
        val remote = attempt { api().getPreferences() } ?: return false
        take(remote)
        return true
    }

    /**
     * Takes the row as the server answered it, from a pull or with a
     * refused push: its value for every key that is not owed, and the
     * flag list merged with this device's when it is. Pulls and pushes
     * run one at a time ([syncing]) and the server reads consistently, so
     * no answer here can be older than the row already held.
     */
    private suspend fun take(remote: RemotePreferences) {
        dataStore.edit { store ->
            val held = ledger(store)
            val current = decode(store)
            val rebased =
                held.rebase(PreferencesWire.rowValues(remote), remote.version, PreferencesWire.toValues(current))
            val apply = PreferencesWire.remoteFor(current, rebased.apply, rebased.ledger.unsent)
            encode(store, accepted(PreferencesWire.applyRemote(current, apply)))
            store.writeLedger(rebased.ledger)
        }
    }

    /**
     * Sends the owed keys until nothing is owed, or until a request fails
     * or is refused. A newer row is taken and the push goes again, a few
     * times at most: more than once means another device wrote between
     * this one's answer and its next request.
     */
    private suspend fun push() {
        var newerRows = 0
        while (newerRows <= NEWER_ROW_LIMIT) {
            val store = dataStore.data.first()
            val held = ledger(store)
            val changes = held.changes(PreferencesWire.toValues(decode(store)))
            if (changes.isEmpty() || changes == refused) return
            if (!held.hasRow) {
                // Nothing is sent before this device has read the row.
                if (!pull()) return
                continue
            }
            val result =
                try {
                    api().setPreferences(PreferencesWire.toUpdate(changes), held.version)
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (refusal: CabalmailException.ApiError) {
                    if (refusal.httpStatus != HTTP_BAD_REQUEST) return
                    // Around again: an edit made while the request was out
                    // has changed what is owed, and gets its own request.
                    refused = changes
                    continue
                } catch (failure: Exception) {
                    // No connection, or the server failed: it stays owed.
                    return
                }
            when (result) {
                is PreferencesSaveResult.Saved ->
                    dataStore.edit { now ->
                        now.writeLedger(
                            ledger(now).took(changes, result.version, PreferencesWire.toValues(decode(now))),
                        )
                    }
                is PreferencesSaveResult.Stale -> {
                    newerRows += 1
                    take(result.row)
                }
            }
        }
    }

    /** [block]'s answer, or null when it failed for any reason but cancellation. */
    private suspend fun <T> attempt(block: suspend () -> T): T? =
        try {
            block()
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (failure: Exception) {
            null
        }

    /**
     * Makes the synced settings the signed-in account's. The store is one
     * per device, so when the account is not the one the settings were
     * last synced for, they and the ledger are put back to their defaults
     * before anything is read or sent (#2471). The first account seen
     * (an install from before this was recorded) keeps what is there.
     */
    private suspend fun ensureAccount() {
        val name = attempt { account() } ?: return
        val id = accountId(name)
        if (dataStore.data.first()[Keys.SYNC_ACCOUNT] == id) return
        dataStore.edit { store ->
            val last = store[Keys.SYNC_ACCOUNT]
            if (last != null && last != id) {
                encode(store, deviceOnly(decode(store)))
                store.remove(Keys.SYNC_LEDGER)
            }
            store[Keys.SYNC_ACCOUNT] = id
        }
        refused = null
    }

    /** [value]'s device-local settings over defaults for every synced one. */
    private fun deviceOnly(value: AppPreferences): AppPreferences =
        AppPreferences(
            dynamicColor = value.dynamicColor,
            notificationsEnabled = value.notificationsEnabled,
            pushFolders = value.pushFolders,
            defaultSort = value.defaultSort,
            defaultSortDescending = value.defaultSortDescending,
            folderFilterSubscribed = value.folderFilterSubscribed,
            folderFilterUnread = value.folderFilterUnread,
            feedCollapsedFolders = value.feedCollapsedFolders,
            feedFilterUnread = value.feedFilterUnread,
        )

    private fun accountId(name: String): String =
        MessageDigest
            .getInstance("SHA-256")
            .digest(name.trim().lowercase().toByteArray())
            .joinToString("") { "%02x".format(it) }

    private fun ledger(store: Preferences): SettingsSyncLedger =
        store[Keys.SYNC_LEDGER]
            ?.let { runCatching { ledgerJson.decodeFromString<SettingsSyncLedger>(it) }.getOrNull() }
            ?: SettingsSyncLedger()

    private fun MutablePreferences.writeLedger(ledger: SettingsSyncLedger) {
        this[Keys.SYNC_LEDGER] = ledgerJson.encodeToString(ledger)
    }

    /**
     * [value] with its typed values as the server takes them. Applied to
     * what a write is about to store, and to what the store holds, which
     * mends a value an older build stored at the next launch.
     */
    private fun accepted(value: AppPreferences): AppPreferences =
        value.copy(
            displayName = ServerTextRules.displayName(value.displayName),
            signature = ServerTextRules.signature(value.signature),
            flagPalette = FlagPalette.accepted(value.flagPalette),
        )

    private fun decode(store: Preferences): AppPreferences = accepted(decodeStored(store))

    private fun decodeStored(store: Preferences): AppPreferences {
        val defaults = AppPreferences()
        return AppPreferences(
            displayName = store[Keys.DISPLAY_NAME] ?: defaults.displayName,
            accent = wireEnum<Accent>(store[Keys.ACCENT]) ?: defaults.accent,
            density = wireEnum<Density>(store[Keys.DENSITY]) ?: defaults.density,
            theme = wireEnum<AppTheme>(store[Keys.THEME]) ?: defaults.theme,
            markAsRead = wireEnum<MarkAsRead>(store[Keys.MARK_AS_READ]) ?: defaults.markAsRead,
            loadRemoteContent =
                wireEnum<LoadRemoteContent>(store[Keys.LOAD_REMOTE_CONTENT]) ?: defaults.loadRemoteContent,
            bodyRenderMode = wireEnum<BodyRenderMode>(store[Keys.BODY_RENDER_MODE]) ?: defaults.bodyRenderMode,
            folderCountDisplay =
                wireEnum<FolderCountDisplay>(store[Keys.FOLDER_COUNT_DISPLAY]) ?: defaults.folderCountDisplay,
            disposeAction = wireEnum<DisposeAction>(store[Keys.DISPOSE_ACTION]) ?: defaults.disposeAction,
            disposeAdvance = wireEnum<DisposeAdvance>(store[Keys.DISPOSE_ADVANCE]) ?: defaults.disposeAdvance,
            defaultFromAddress = store[Keys.DEFAULT_FROM_ADDRESS]?.ifEmpty { null },
            signature = store[Keys.SIGNATURE] ?: defaults.signature,
            flagPalette = store[Keys.FLAG_PALETTE]?.let(FlagPalette::decode) ?: defaults.flagPalette,
            flagPaletteSyncable = store[Keys.FLAG_PALETTE_SYNCABLE] ?: defaults.flagPaletteSyncable,
            mailFolderFilters = MailFolderFilters.decode(store[Keys.MAIL_FOLDER_FILTERS]),
            rssMarkAsRead = wireEnum<MarkAsRead>(store[Keys.RSS_MARK_AS_READ]),
            feedsAllFilter = wireEnum<RssItemFilter>(store[Keys.FEEDS_ALL_FILTER]),
            swipeLeading = wireEnum<MailSwipeAction>(store[Keys.SWIPE_LEADING]),
            swipeTrailing = wireEnum<MailSwipeAction>(store[Keys.SWIPE_TRAILING]),
            rssSwipeLeading = wireEnum<FeedSwipeAction>(store[Keys.RSS_SWIPE_LEADING]),
            rssSwipeTrailing = wireEnum<FeedSwipeAction>(store[Keys.RSS_SWIPE_TRAILING]),
            dynamicColor = store[Keys.DYNAMIC_COLOR] ?: defaults.dynamicColor,
            notificationsEnabled = store[Keys.NOTIFICATIONS_ENABLED] ?: defaults.notificationsEnabled,
            pushFolders = store[Keys.PUSH_FOLDERS] ?: defaults.pushFolders,
            defaultSort = wireEnum<DefaultSort>(store[Keys.DEFAULT_SORT]) ?: defaults.defaultSort,
            defaultSortDescending = store[Keys.DEFAULT_SORT_DESCENDING] ?: defaults.defaultSortDescending,
            folderFilterSubscribed = store[Keys.FOLDER_FILTER_SUBSCRIBED] ?: defaults.folderFilterSubscribed,
            folderFilterUnread = store[Keys.FOLDER_FILTER_UNREAD] ?: defaults.folderFilterUnread,
            feedCollapsedFolders = store[Keys.FEED_COLLAPSED_FOLDERS] ?: defaults.feedCollapsedFolders,
            feedFilterUnread = store[Keys.FEED_FILTER_UNREAD] ?: defaults.feedFilterUnread,
        )
    }

    private fun encode(
        store: MutablePreferences,
        value: AppPreferences,
    ) {
        store[Keys.DISPLAY_NAME] = value.displayName
        store[Keys.ACCENT] = value.accent.wire
        store[Keys.DENSITY] = value.density.wire
        store[Keys.THEME] = value.theme.wire
        store[Keys.MARK_AS_READ] = value.markAsRead.wire
        store[Keys.LOAD_REMOTE_CONTENT] = value.loadRemoteContent.wire
        store[Keys.BODY_RENDER_MODE] = value.bodyRenderMode.wire
        store[Keys.FOLDER_COUNT_DISPLAY] = value.folderCountDisplay.wire
        store[Keys.DISPOSE_ACTION] = value.disposeAction.wire
        store[Keys.DISPOSE_ADVANCE] = value.disposeAdvance.wire
        store[Keys.DEFAULT_FROM_ADDRESS] = value.defaultFromAddress.orEmpty()
        store[Keys.SIGNATURE] = value.signature
        store[Keys.FLAG_PALETTE] = FlagPalette.encode(value.flagPalette)
        store[Keys.FLAG_PALETTE_SYNCABLE] = value.flagPaletteSyncable
        store[Keys.MAIL_FOLDER_FILTERS] = MailFolderFilters.encode(value.mailFolderFilters)
        // Absent, not defaulted: null means "never set", which keeps the key off the wire.
        value.rssMarkAsRead?.let { store[Keys.RSS_MARK_AS_READ] = it.wire } ?: store.remove(Keys.RSS_MARK_AS_READ)
        value.feedsAllFilter?.let { store[Keys.FEEDS_ALL_FILTER] = it.wire } ?: store.remove(Keys.FEEDS_ALL_FILTER)
        value.swipeLeading?.let { store[Keys.SWIPE_LEADING] = it.wire } ?: store.remove(Keys.SWIPE_LEADING)
        value.swipeTrailing?.let { store[Keys.SWIPE_TRAILING] = it.wire } ?: store.remove(Keys.SWIPE_TRAILING)
        value.rssSwipeLeading?.let { store[Keys.RSS_SWIPE_LEADING] = it.wire }
            ?: store.remove(Keys.RSS_SWIPE_LEADING)
        value.rssSwipeTrailing?.let { store[Keys.RSS_SWIPE_TRAILING] = it.wire }
            ?: store.remove(Keys.RSS_SWIPE_TRAILING)
        store[Keys.DYNAMIC_COLOR] = value.dynamicColor
        store[Keys.NOTIFICATIONS_ENABLED] = value.notificationsEnabled
        store[Keys.PUSH_FOLDERS] = value.pushFolders
        store[Keys.DEFAULT_SORT] = value.defaultSort.wire
        store[Keys.DEFAULT_SORT_DESCENDING] = value.defaultSortDescending
        store[Keys.FOLDER_FILTER_SUBSCRIBED] = value.folderFilterSubscribed
        store[Keys.FOLDER_FILTER_UNREAD] = value.folderFilterUnread
        store[Keys.FEED_COLLAPSED_FOLDERS] = value.feedCollapsedFolders
        store[Keys.FEED_FILTER_UNREAD] = value.feedFilterUnread
    }

    companion object {
        const val PUSH_DEBOUNCE_MS = 800L

        /** How many newer rows one push takes before it leaves the rest to the next trigger. */
        private const val NEWER_ROW_LIMIT = 3
        private const val HTTP_BAD_REQUEST = 400
    }
}

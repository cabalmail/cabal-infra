package com.cabalmail.kit.settings

import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.booleanPreferencesKey
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import com.cabalmail.kit.api.ApiClient
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

/**
 * The preference store (plan §6.3): a DataStore-backed local cache that is
 * the source of truth for the UI, plus the server sync that keeps the
 * shared subset consistent with the web and Apple clients.
 *
 * - On sign-in / launch, [refreshFromServer] pulls `/get_preferences` and
 *   applies it (server wins), the way the Apple client does.
 * - Every local [update] writes DataStore immediately and pushes the full
 *   synced payload on a short debounce; the server merges per key.
 * - Local-only fields (dynamic color, default sort) never leave the device.
 */
@OptIn(FlowPreview::class)
class PreferencesRepository(
    private val dataStore: DataStore<Preferences>,
    private val scope: CoroutineScope,
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
        val DEFAULT_FROM_ADDRESS = stringPreferencesKey("default_from_address")
        val SIGNATURE = stringPreferencesKey("signature")
        val DYNAMIC_COLOR = booleanPreferencesKey("dynamic_color")
        val DEFAULT_SORT = stringPreferencesKey("default_sort")
        val DEFAULT_SORT_DESCENDING = booleanPreferencesKey("default_sort_descending")
    }

    private val pushRequests = MutableSharedFlow<Unit>(extraBufferCapacity = 1)

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

    /** Applies a local change and schedules the server push. */
    suspend fun update(transform: (AppPreferences) -> AppPreferences) {
        val next = transform(decode(dataStore.data.first()))
        dataStore.edit { store -> encode(store, next) }
        pushRequests.tryEmit(Unit)
    }

    /**
     * Pulls the server's copy and applies it over the local cache (server
     * wins). Failures are swallowed — the cache is a fine fallback and the
     * next launch retries.
     */
    suspend fun refreshFromServer() {
        val remote = runCatching { api().getPreferences() }.getOrNull() ?: return
        val merged = PreferencesWire.applyRemote(decode(dataStore.data.first()), remote)
        dataStore.edit { store -> encode(store, merged) }
    }

    private suspend fun pushToServer() {
        val current = decode(dataStore.data.first())
        runCatching { api().setPreferences(PreferencesWire.toUpdate(current)) }
    }

    private fun decode(store: Preferences): AppPreferences {
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
            defaultFromAddress = store[Keys.DEFAULT_FROM_ADDRESS]?.ifEmpty { null },
            signature = store[Keys.SIGNATURE] ?: defaults.signature,
            dynamicColor = store[Keys.DYNAMIC_COLOR] ?: defaults.dynamicColor,
            defaultSort = wireEnum<DefaultSort>(store[Keys.DEFAULT_SORT]) ?: defaults.defaultSort,
            defaultSortDescending = store[Keys.DEFAULT_SORT_DESCENDING] ?: defaults.defaultSortDescending,
        )
    }

    private fun encode(
        store: androidx.datastore.preferences.core.MutablePreferences,
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
        store[Keys.DEFAULT_FROM_ADDRESS] = value.defaultFromAddress.orEmpty()
        store[Keys.SIGNATURE] = value.signature
        store[Keys.DYNAMIC_COLOR] = value.dynamicColor
        store[Keys.DEFAULT_SORT] = value.defaultSort.wire
        store[Keys.DEFAULT_SORT_DESCENDING] = value.defaultSortDescending
    }

    companion object {
        const val PUSH_DEBOUNCE_MS = 800L
    }
}

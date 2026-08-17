package com.cabalmail.android.navigation

import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import com.cabalmail.kit.api.ApiClient
import com.cabalmail.kit.models.NavState
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.filterNotNull
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import java.util.UUID

/** A restored server cursor; [local] when this install wrote it. */
data class RestoredCursor(
    val state: NavState,
    val local: Boolean,
)

/**
 * The plan's resume cursor (§4.5): position updates are debounced into
 * `/set_nav_state` stamped with a per-install client id, and launch reads
 * the stored cursor back to offer (or silently perform) a restore. The
 * client id lives in un-backed-up DataStore — data_extraction_rules.xml
 * excludes everything — so each install stays distinguishable.
 */
class NavCursor(
    private val dataStore: DataStore<Preferences>,
    scope: CoroutineScope,
    private val api: suspend () -> ApiClient,
) {
    private val pending = MutableStateFlow<NavState?>(null)
    private var restored = false

    init {
        scope.launch {
            pending.filterNotNull().collectLatest { state ->
                delay(WRITE_DEBOUNCE_MS)
                // Cursor loss is harmless; drop failures silently rather
                // than surfacing errors for a background nicety.
                runCatching { api().setNavState(state.copy(clientId = clientId())) }
            }
        }
    }

    /** Queues a debounced cursor write; the latest position wins. */
    fun record(
        folder: String,
        uid: Long? = null,
        messageId: String? = null,
        listScroll: Long? = null,
    ) {
        pending.value =
            NavState(
                folder = folder,
                uid = uid,
                messageId = messageId,
                listScroll = listScroll,
            )
    }

    /**
     * The stored cursor, once per process — later calls (e.g. after
     * sign-out/sign-in remounts navigation) return null so the app doesn't
     * yank the user around twice.
     */
    suspend fun restoreOnce(): RestoredCursor? {
        if (restored) {
            return null
        }
        restored = true
        val state = runCatching { api().getNavState() }.getOrNull() ?: return null
        if (state.folder == null) {
            return null
        }
        return RestoredCursor(state = state, local = state.clientId == clientId())
    }

    private suspend fun clientId(): String {
        val existing = dataStore.data.first()[CLIENT_ID_KEY]
        if (existing != null) {
            return existing
        }
        val created = UUID.randomUUID().toString()
        dataStore.edit { prefs ->
            // Keep a concurrent writer's value if one raced us in.
            if (prefs[CLIENT_ID_KEY] == null) {
                prefs[CLIENT_ID_KEY] = created
            }
        }
        return dataStore.data.first()[CLIENT_ID_KEY] ?: created
    }

    companion object {
        private const val WRITE_DEBOUNCE_MS = 1_500L
        private val CLIENT_ID_KEY = stringPreferencesKey("nav_client_id")
    }
}

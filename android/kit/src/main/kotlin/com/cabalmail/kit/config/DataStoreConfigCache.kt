package com.cabalmail.kit.config

import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import kotlinx.coroutines.flow.first

/**
 * [ConfigCache] backed by Jetpack DataStore. Plain (unencrypted) storage is
 * deliberate: every value in `config.json` is also served publicly from the
 * control domain, and the domain itself is what the user typed, so there is
 * nothing to protect at rest.
 */
class DataStoreConfigCache(
    private val dataStore: DataStore<Preferences>,
) : ConfigCache {
    override suspend fun read(): CachedConfig? {
        val preferences = dataStore.data.first()
        // An entry written before the control domain was stored alongside the
        // payload (builds that baked the domain in) has no way to say which
        // server it came from, so it is not a usable cache.
        val controlDomain = preferences[KEY_CONTROL_DOMAIN] ?: return null
        val raw = preferences[KEY_CONFIG_JSON] ?: return null
        return CachedConfig(controlDomain, raw)
    }

    override suspend fun write(
        controlDomain: String,
        raw: String,
    ) {
        dataStore.edit { preferences ->
            preferences[KEY_CONTROL_DOMAIN] = controlDomain
            preferences[KEY_CONFIG_JSON] = raw
        }
    }

    private companion object {
        val KEY_CONTROL_DOMAIN = stringPreferencesKey("control_domain")
        val KEY_CONFIG_JSON = stringPreferencesKey("config_json")
    }
}

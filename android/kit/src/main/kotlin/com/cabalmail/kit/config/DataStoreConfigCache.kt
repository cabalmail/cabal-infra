package com.cabalmail.kit.config

import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import kotlinx.coroutines.flow.first

/**
 * [ConfigCache] backed by Jetpack DataStore. Plain (unencrypted) storage is
 * deliberate: every value in `config.json` is also served publicly from the
 * control domain, so there is nothing to protect at rest.
 */
class DataStoreConfigCache(
    private val dataStore: DataStore<Preferences>,
) : ConfigCache {
    override suspend fun read(): String? = dataStore.data.first()[KEY_CONFIG_JSON]

    override suspend fun write(raw: String) {
        dataStore.edit { preferences ->
            preferences[KEY_CONFIG_JSON] = raw
        }
    }

    private companion object {
        val KEY_CONFIG_JSON = stringPreferencesKey("config_json")
    }
}

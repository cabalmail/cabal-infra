package com.cabalmail.kit.auth

import android.content.Context
import android.content.SharedPreferences
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKeys
import kotlinx.serialization.json.Json

/**
 * [TokenStore] backed by `EncryptedSharedPreferences` (Android
 * Keystore-wrapped AES). The file is excluded from backup and device
 * transfer wholesale by `data_extraction_rules.xml`, and Keystore keys
 * would not survive a restore anyway.
 */
class EncryptedTokenStore(
    context: Context,
) : TokenStore {
    private val json = Json { ignoreUnknownKeys = true }

    private val preferences: SharedPreferences =
        EncryptedSharedPreferences.create(
            "cabalmail_auth",
            MasterKeys.getOrCreate(MasterKeys.AES256_GCM_SPEC),
            context,
            EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
            EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
        )

    override fun readTokens(): AuthTokens? =
        preferences
            .getString(KEY_TOKENS, null)
            ?.let { raw -> runCatching { json.decodeFromString<AuthTokens>(raw) }.getOrNull() }

    override fun writeTokens(tokens: AuthTokens) {
        preferences.edit().putString(KEY_TOKENS, json.encodeToString(AuthTokens.serializer(), tokens)).apply()
    }

    override fun readUsername(): String? = preferences.getString(KEY_USERNAME, null)

    override fun writeUsername(username: String) {
        preferences.edit().putString(KEY_USERNAME, username).apply()
    }

    override fun clear() {
        preferences.edit().clear().apply()
    }

    private companion object {
        const val KEY_TOKENS = "auth_tokens"
        const val KEY_USERNAME = "username"
    }
}

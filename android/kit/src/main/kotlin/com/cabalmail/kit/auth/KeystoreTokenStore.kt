package com.cabalmail.kit.auth

import android.content.Context
import android.content.SharedPreferences
import kotlinx.serialization.json.Json

/**
 * The minimal `SharedPreferences` surface [KeystoreTokenStore] needs, so the
 * store's read/write/migrate logic runs on the JVM without the framework.
 */
internal interface KeyValueStorage {
    fun getString(key: String): String?

    fun putString(
        key: String,
        value: String,
    )

    fun clear()
}

/** Read side of whatever store an upgrade is migrating away from. */
internal interface LegacyStore {
    fun readTokensJson(): String?

    fun readUsername(): String?

    fun clear()
}

/**
 * [TokenStore] backed by ordinary `SharedPreferences` holding values encrypted
 * under an Android Keystore AES-GCM key.
 *
 * This replaces `EncryptedSharedPreferences`, which
 * `androidx.security:security-crypto` 1.1.0 deprecates wholesale — Google
 * retired the library rather than replacing the API (#1152). The posture is
 * unchanged (a Keystore-wrapped key the app cannot export); only the key
 * handling moves into code we own.
 *
 * Values the old store wrote are migrated on first construction so an upgrade
 * does not sign the user out — see [LegacyEncryptedTokenStore].
 */
class KeystoreTokenStore internal constructor(
    private val storage: KeyValueStorage,
    private val cipher: ValueCipher,
    private val legacy: () -> LegacyStore?,
) : TokenStore {
    private val json = Json { ignoreUnknownKeys = true }

    init {
        migrateIfNeeded()
    }

    constructor(context: Context) : this(
        storage = SharedPreferencesStorage(context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)),
        cipher = keystoreValueCipher(KEY_ALIAS),
        legacy = { LegacyEncryptedTokenStore.openIfPresent(context) },
    )

    override fun readTokens(): AuthTokens? =
        decrypted(KEY_TOKENS)?.let { raw -> runCatching { json.decodeFromString<AuthTokens>(raw) }.getOrNull() }

    override fun writeTokens(tokens: AuthTokens) {
        storage.putString(KEY_TOKENS, cipher.encrypt(json.encodeToString(AuthTokens.serializer(), tokens)))
    }

    override fun readUsername(): String? = decrypted(KEY_USERNAME)

    override fun writeUsername(username: String) {
        storage.putString(KEY_USERNAME, cipher.encrypt(username))
    }

    override fun clear() {
        storage.clear()
        // Signing out must not re-arm the migration: the old store has already
        // been drained and emptied, so a second pass would only re-open a
        // deprecated file to find nothing in it.
        storage.putString(KEY_MIGRATED, MIGRATED)
    }

    private fun decrypted(key: String): String? = storage.getString(key)?.let { cipher.decrypt(it) }

    /**
     * Moves the old store's values across once, then empties it. The marker is
     * written whether or not anything was found, so a fresh install pays the
     * lookup at most once.
     */
    private fun migrateIfNeeded() {
        if (storage.getString(KEY_MIGRATED) != null) return
        val old = legacy()
        if (old != null) {
            old.readTokensJson()?.let { storage.putString(KEY_TOKENS, cipher.encrypt(it)) }
            old.readUsername()?.let { storage.putString(KEY_USERNAME, cipher.encrypt(it)) }
            old.clear()
        }
        storage.putString(KEY_MIGRATED, MIGRATED)
    }

    internal companion object {
        const val PREFS_NAME = "cabalmail_auth_v2"
        const val KEY_ALIAS = "cabalmail_auth"
        const val KEY_TOKENS = "auth_tokens"
        const val KEY_USERNAME = "username"
        const val KEY_MIGRATED = "migrated_from_encrypted_prefs"
        const val MIGRATED = "1"
    }
}

/** The production [KeyValueStorage]; holds ciphertext only. */
private class SharedPreferencesStorage(
    private val preferences: SharedPreferences,
) : KeyValueStorage {
    override fun getString(key: String): String? = preferences.getString(key, null)

    override fun putString(
        key: String,
        value: String,
    ) {
        preferences.edit().putString(key, value).apply()
    }

    override fun clear() {
        preferences.edit().clear().apply()
    }
}

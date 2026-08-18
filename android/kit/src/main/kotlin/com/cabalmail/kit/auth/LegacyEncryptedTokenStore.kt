package com.cabalmail.kit.auth

import android.content.Context
import android.content.SharedPreferences
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKeys
import java.io.File

/**
 * Read side of the retired `EncryptedSharedPreferences` store, kept only so an
 * upgrade can hand its values to [KeystoreTokenStore] instead of signing the
 * user out.
 *
 * The deprecation suppressed here is Google retiring
 * `androidx.security:security-crypto` wholesale (#1152), not an API we are
 * misusing. It is scoped to this migration path deliberately: nothing else in
 * the app reads the old file, and this class (with the dependency) goes away
 * once no supported install is still upgrading across the change.
 */
@Suppress("DEPRECATION")
internal class LegacyEncryptedTokenStore private constructor(
    private val preferences: SharedPreferences,
) : LegacyStore {
    override fun readTokensJson(): String? = preferences.getString(KEY_TOKENS, null)

    override fun readUsername(): String? = preferences.getString(KEY_USERNAME, null)

    override fun clear() {
        preferences.edit().clear().apply()
    }

    companion object {
        private const val PREFS_NAME = "cabalmail_auth"
        private const val KEY_TOKENS = "auth_tokens"
        private const val KEY_USERNAME = "username"

        /**
         * Null on a fresh install (no old file to open — creating one just to
         * read nothing would be the only reason left to keep the library), and
         * null when the file cannot be decrypted: a Keystore key lost to a
         * restore throws here, and a failed migration must cost a sign-in, not
         * a crash on launch.
         */
        fun openIfPresent(context: Context): LegacyStore? {
            val file = File(File(context.applicationInfo.dataDir, "shared_prefs"), "$PREFS_NAME.xml")
            if (!file.exists()) return null
            return runCatching {
                LegacyEncryptedTokenStore(
                    EncryptedSharedPreferences.create(
                        PREFS_NAME,
                        MasterKeys.getOrCreate(MasterKeys.AES256_GCM_SPEC),
                        context,
                        EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
                        EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
                    ),
                )
            }.getOrNull()
        }
    }
}

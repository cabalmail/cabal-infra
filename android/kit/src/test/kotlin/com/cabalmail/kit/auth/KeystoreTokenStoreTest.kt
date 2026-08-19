package com.cabalmail.kit.auth

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNotEquals
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import javax.crypto.KeyGenerator

/**
 * Covers the store's read/write/migration decisions and the AES-GCM envelope
 * with a plain JVM key. Key *provisioning* (Android Keystore) and the
 * `SharedPreferences` adapter are the only parts left to a device — everything
 * that decides what is stored, and whether an upgrade keeps the session, runs
 * here.
 */
class KeystoreTokenStoreTest {
    private class FakeStorage(
        val values: MutableMap<String, String> = mutableMapOf(),
    ) : KeyValueStorage {
        override fun getString(key: String): String? = values[key]

        override fun putString(
            key: String,
            value: String,
        ) {
            values[key] = value
        }

        override fun clear() = values.clear()
    }

    private class FakeLegacyStore(
        var tokensJson: String?,
        var username: String?,
    ) : LegacyStore {
        var cleared = false

        override fun readTokensJson(): String? = tokensJson

        override fun readUsername(): String? = username

        override fun clear() {
            cleared = true
            tokensJson = null
            username = null
        }
    }

    /** Counts how often the store reached for the retired store. */
    private class CountingLegacy(
        private val value: LegacyStore?,
    ) : () -> LegacyStore? {
        var opened = 0

        override fun invoke(): LegacyStore? {
            opened++
            return value
        }
    }

    private val key = KeyGenerator.getInstance("AES").apply { init(AES_BITS) }.generateKey()
    private val cipher = AesGcmValueCipher { key }

    private fun store(
        storage: KeyValueStorage = FakeStorage(),
        legacy: () -> LegacyStore? = { null },
    ) = KeystoreTokenStore(storage, cipher, legacy)

    private fun tokens(idToken: String = "id-token") =
        AuthTokens(
            idToken = idToken,
            accessToken = "access-token",
            refreshToken = "refresh-token",
            expiresAtEpochMillis = 1_800_000_000_000L,
        )

    @Test
    fun `round-trips tokens and username`() {
        val storage = FakeStorage()
        val subject = store(storage)

        subject.writeTokens(tokens())
        subject.writeUsername("claude")

        assertEquals(tokens(), subject.readTokens())
        assertEquals("claude", subject.readUsername())
    }

    @Test
    fun `stores ciphertext, not the tokens themselves`() {
        val storage = FakeStorage()

        store(storage).writeTokens(tokens())

        val stored = storage.values.getValue(KeystoreTokenStore.KEY_TOKENS)
        assertFalse(stored.contains("refresh-token"), "refresh token found in plaintext at rest: $stored")
        assertFalse(stored.contains("idToken"), "JSON structure found in plaintext at rest: $stored")
    }

    @Test
    fun `encrypts with a fresh IV each time`() {
        val storage = FakeStorage()
        val subject = store(storage)

        subject.writeUsername("claude")
        val first = storage.values.getValue(KeystoreTokenStore.KEY_USERNAME)
        subject.writeUsername("claude")
        val second = storage.values.getValue(KeystoreTokenStore.KEY_USERNAME)

        assertNotEquals(first, second, "the same value encrypted twice produced the same blob")
        assertEquals("claude", subject.readUsername())
    }

    @Test
    fun `reads null rather than throwing when a blob has been tampered with`() {
        val storage = FakeStorage()
        val subject = store(storage)
        subject.writeTokens(tokens())
        subject.writeUsername("claude")

        val blob = storage.values.getValue(KeystoreTokenStore.KEY_TOKENS)
        storage.values[KeystoreTokenStore.KEY_TOKENS] = blob.dropLast(4) + "AAAA"
        storage.values[KeystoreTokenStore.KEY_USERNAME] = "not base64 at all"

        assertNull(subject.readTokens())
        assertNull(subject.readUsername())
    }

    @Test
    fun `migrates an existing session instead of signing the user out`() {
        val storage = FakeStorage()
        val legacy =
            FakeLegacyStore(
                tokensJson =
                    """{"idToken":"id-token","accessToken":"access-token",""" +
                        """"refreshToken":"refresh-token","expiresAtEpochMillis":1800000000000}""",
                username = "claude",
            )

        val subject = store(storage) { legacy }

        assertEquals(tokens(), subject.readTokens())
        assertEquals("claude", subject.readUsername())
        assertTrue(legacy.cleared, "the old store kept its copy of the tokens")
        assertFalse(
            storage.values.getValue(KeystoreTokenStore.KEY_TOKENS).contains("refresh-token"),
            "migrated tokens were written through unencrypted",
        )
    }

    @Test
    fun `migrates once, then stops consulting the old store`() {
        val storage = FakeStorage()
        val legacy = CountingLegacy(FakeLegacyStore(tokensJson = null, username = "claude"))

        store(storage, legacy)
        store(storage, legacy)

        assertEquals(1, legacy.opened, "the retired store was opened again after the migration")
        assertEquals("claude", store(storage, legacy).readUsername())
    }

    @Test
    fun `marks a fresh install migrated without an old store present`() {
        val storage = FakeStorage()

        store(storage) { null }

        assertEquals(KeystoreTokenStore.MIGRATED, storage.values[KeystoreTokenStore.KEY_MIGRATED])
        assertNull(store(storage) { null }.readTokens())
    }

    @Test
    fun `signing out clears the session but not the migration marker`() {
        val storage = FakeStorage()
        val legacy = CountingLegacy(null)
        val subject = store(storage, legacy)
        subject.writeTokens(tokens())
        subject.writeUsername("claude")

        subject.clear()

        assertNull(subject.readTokens())
        assertNull(subject.readUsername())
        store(storage, legacy)
        assertEquals(1, legacy.opened, "signing out re-armed the migration")
    }

    @Test
    fun `reads null when the stored JSON is not tokens`() {
        val storage = FakeStorage()
        val subject = store(storage)
        storage.values[KeystoreTokenStore.KEY_TOKENS] = cipher.encrypt("""{"unexpected":true}""")

        assertNull(subject.readTokens())
    }

    private companion object {
        const val AES_BITS = 256
    }
}

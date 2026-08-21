package com.cabalmail.kit.auth

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import java.security.KeyStore
import java.util.Base64
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * Encrypts the values [KeystoreTokenStore] persists. A seam, so the envelope
 * format is exercisable on the JVM with an ordinary AES key — only key
 * provisioning needs a device.
 */
internal interface ValueCipher {
    fun encrypt(plaintext: String): String

    /** Null when the blob is not ours, is truncated, or fails its GCM tag. */
    fun decrypt(encoded: String): String?
}

/**
 * AES-GCM with a fresh IV per encryption, stored as
 * base64(iv || ciphertext-with-tag). GCM authenticates, so a tampered or
 * truncated blob decrypts to null rather than to plausible garbage.
 *
 * The IV comes from the cipher rather than from us: AndroidKeyStore rejects a
 * caller-supplied IV on encryption, and generating one per call is what keeps
 * GCM safe under key reuse.
 */
internal class AesGcmValueCipher(
    private val key: () -> SecretKey,
) : ValueCipher {
    override fun encrypt(plaintext: String): String {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, key())
        val ciphertext = cipher.doFinal(plaintext.toByteArray(Charsets.UTF_8))
        return Base64.getEncoder().encodeToString(cipher.iv + ciphertext)
    }

    override fun decrypt(encoded: String): String? =
        runCatching {
            val blob = Base64.getDecoder().decode(encoded)
            require(blob.size > IV_BYTES)
            val cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(TAG_BITS, blob, 0, IV_BYTES))
            String(cipher.doFinal(blob, IV_BYTES, blob.size - IV_BYTES), Charsets.UTF_8)
        }.getOrNull()

    private companion object {
        const val TRANSFORMATION = "AES/GCM/NoPadding"
        const val IV_BYTES = 12
        const val TAG_BITS = 128
    }
}

/**
 * A [ValueCipher] over an Android Keystore key, generated on first use and
 * never exportable. Keystore keys do not survive a restore or a device
 * transfer, which is why `data_extraction_rules.xml` excludes this app's
 * storage from both.
 */
internal fun keystoreValueCipher(alias: String): ValueCipher {
    val key = lazy { keystoreSecretKey(alias) }
    return AesGcmValueCipher { key.value }
}

private const val ANDROID_KEYSTORE = "AndroidKeyStore"

private fun keystoreSecretKey(alias: String): SecretKey {
    val keystore = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
    (keystore.getEntry(alias, null) as? KeyStore.SecretKeyEntry)?.let { return it.secretKey }
    val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, ANDROID_KEYSTORE)
    generator.init(
        KeyGenParameterSpec
            .Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setKeySize(256)
            .build(),
    )
    return generator.generateKey()
}

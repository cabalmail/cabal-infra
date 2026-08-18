- Android: **Sign-in tokens now use an Android Keystore key the app manages
  itself.** The library the client relied on for at-rest token encryption,
  `androidx.security:security-crypto`, has been retired upstream rather than
  replaced, so its `EncryptedSharedPreferences` is gone from the auth path.
  Tokens are now encrypted with an AES-GCM key held in the Android Keystore —
  the same protection, without an abandoned dependency guarding the session.
  An existing session is migrated on the first launch after updating, so
  signing in again should not be necessary.

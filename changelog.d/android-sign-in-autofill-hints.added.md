- Android: **Autofill hints on the sign-in form.** The username, password,
  and verification-code fields now carry autofill content types, so a
  password manager offers the saved login and its one-time code instead
  of guessing. The admin origin also publishes `assetlinks.json` when
  `TF_VAR_ANDROID_SIGNING_CERT_FINGERPRINTS` is set, which links the app
  to the web login without the manager asking first. See
  `docs/password-autofill.md`.

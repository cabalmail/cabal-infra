- **Cognito sign-in for the Linux client.** `cabalmail-kit` signs in with
  `USER_PASSWORD_AUTH` against the deployment's user pool, answers TOTP and
  SMS challenges, and covers sign-up, confirmation, password reset, and TOTP
  enrollment, with the `otpauth://` URI an authenticator app reads. Tokens
  refresh 30 seconds before expiry; concurrent requests that find them stale
  share one refresh, and signing out while a refresh is in flight stays signed
  out. Cognito's refusals reach the caller by name with Cognito's own message,
  so an unconfirmed account can be sent to confirmation rather than shown an
  error. Nothing in the app signs in yet.

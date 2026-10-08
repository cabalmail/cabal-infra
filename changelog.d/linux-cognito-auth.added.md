- **Cognito sign-in for the Linux client.** `cabalmail-kit` signs in with
  `USER_PASSWORD_AUTH` against the deployment's user pool, answers TOTP and
  SMS challenges, and covers sign-up, confirmation, password reset, and TOTP
  enrollment, with the `otpauth://` URI an authenticator app reads. Tokens
  refresh 30 seconds before expiry, and concurrent requests that find them
  stale share one refresh and its outcome. Signing out while a refresh is in
  flight stays signed out, and a refresh the pool refuses for good, such as
  under MFA enforcement, ends the session with the pool's explanation.
  Cognito's refusals reach the caller by name with Cognito's own message, so
  an unconfirmed account can be sent to confirmation and a locked account is
  not told its password was wrong. Nothing in the app signs in yet.

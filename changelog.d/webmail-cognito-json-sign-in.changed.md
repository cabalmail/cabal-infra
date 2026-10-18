- **Webmail sign-in off `amazon-cognito-identity-js`.** Every webmail
  auth flow (sign-up, sign-in with TOTP or SMS, the locked-out TOTP
  setup, password reset, the recovery-email gate and the Security
  view) now runs on the first-party Cognito JSON client. The library,
  whose support ends 2027-03-01, is removed, along with the Vite
  `global` shim and the `js-cookie` override it needed. Sign-in uses
  `USER_PASSWORD_AUTH` instead of SRP. A session survives a reload but
  not a new tab: only the refresh token is kept, in sessionStorage, and
  the library's tokens are deleted from localStorage on load, so
  everyone signs in once more after the upgrade. A token near expiry is
  refreshed instead of signing the user out after 12 hours. An expired
  MFA challenge now says so and restarts the sign-in, and sign-in no
  longer fails on an ID token whose claims hold `~`, `?` or `>`.

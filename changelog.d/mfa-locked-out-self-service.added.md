- **Self-service MFA enrollment for locked-out accounts.** When the
  `require_admin_mfa` gate is enforcing and rejects a password sign-in
  because the account holds no MFA factor, the web app now offers a
  "Set up authenticator app" flow instead of a dead end: it
  re-authenticates through a dedicated enrollment app client that the
  gate passes for factorless users only, shows the TOTP QR code, and
  confirms the first code, after which the normal sign-in proceeds
  with a TOTP challenge. The gate's rejection message now points at
  the web app rather than a Security page the blocked user cannot
  reach.

- Cognito threat protection is enabled in audit mode (`advanced_security_mode
  = "AUDIT"`), scoring sign-in risk (impossible travel, compromised
  credentials) without blocking. Refresh tokens now expire in 7 days instead
  of the 30-day default, bounding the exposure of a stolen token, and token
  revocation is set explicitly so a global sign-out reliably invalidates
  issued tokens. Audit-mode threat protection is a paid Cognito feature billed
  per monthly active user.

- Cognito threat protection is enabled in audit mode (`advanced_security_mode
  = "AUDIT"`), scoring sign-in risk (impossible travel, compromised
  credentials) without blocking. The user pool moves to the Plus feature plan
  (threat protection is unavailable on Essentials), which is billed per
  monthly active user from the first user. Refresh tokens now expire in 7
  days instead of the 30-day default, bounding the exposure of a stolen
  token, and token revocation is set explicitly so a global sign-out reliably
  invalidates issued tokens.

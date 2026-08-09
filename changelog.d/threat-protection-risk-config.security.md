- Threat protection's responses are now pinned instead of inheriting
  Cognito's defaults: account-takeover risk answers with a TOTP challenge for
  enrolled users (never a hard block, so the password-only service accounts
  that carry the mail path cannot be cut off by a risk misfire), low-level
  noise is ignored, and sign-ins with a breach-corpus password are blocked
  outright. The configuration is inert in audit mode; it defines exactly what
  enforced mode does when `TF_VAR_THREAT_PROTECTION_ENFORCED` is flipped.

- **Unreachable MFA setup screen for locked-out admins.** The session
  check ran on every render and bounced any logged-out view that was not
  on its allowlist back to the login form, and `MfaSetup` was missing
  from it — so an admin blocked by the MFA gate never saw the
  self-service enrollment screen the gate routes them to. Reloading that
  screen still returns to login, since the password it re-authenticates
  with is deliberately never persisted.

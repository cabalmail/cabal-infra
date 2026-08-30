- **Extension popup no longer wedges when the control domain is
  unreachable.** A dev build made without `CABALMAIL_CONTROL_DOMAIN` (or
  any network failure reaching the admin origin) left the popup stuck on
  "Loading…" with a raw `TypeError: Failed to fetch`. Auth-state and
  sign-out now work from local token storage without touching the network,
  and fetch failures render as an actionable message naming the origin.
  The Chrome extension ID is also now pinned via a manifest `key`, so dev
  builds, the future store listing, and the Cognito OAuth redirect URI all
  share one known ID.

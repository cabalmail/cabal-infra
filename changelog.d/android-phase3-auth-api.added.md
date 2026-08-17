- **Android authentication and API client (Phase 3 core).** Hand-rolled
  Cognito `USER_PASSWORD_AUTH` client with TOTP/SMS challenge handling,
  automatic token refresh, and Keystore-encrypted session storage; the full
  Lambda API surface (`ApiClient` — folders, envelopes, search, messages,
  attachments, flags/moves, compose/drafts, preferences, nav state) with
  single-replay 401 recovery; and a working sign-in screen. 15 new unit
  tests pin the wire contract's quirks (uid-keyed envelope maps, `REVERSE `
  sort order, 409 duplicate-in-flight, maintenance 503s).

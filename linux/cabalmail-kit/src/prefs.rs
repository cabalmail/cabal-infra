//! Server-synced preferences: the `app`-map keys the Apple and web clients
//! already use, their scopes, and reconciliation with the local store.
//!
//! Lands in Phase 6. The synced key set is closed server-side
//! (`APP_ALLOWED` in `lambda/api/set_preferences/function.py`), so this module
//! validates locally and reports the offending key with its file position
//! rather than forwarding a 400.

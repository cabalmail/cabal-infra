//! Token storage: a `SecretStore` trait over the Secret Service (`oo7`), plus
//! an in-memory double for tests. Entries are keyed by
//! `(control_domain, username)` so two accounts never collide.
//!
//! Lands in Phase 3, work item 3. Note the failure mode specified there: a
//! desktop with no keyring daemon gets an actionable message, never a silent
//! fall-back to a plaintext file.

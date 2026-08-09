//! The `ApiClient` trait and its `reqwest` implementation — the client's only
//! transport. There is no IMAP library and no SMTP path here by design; see
//! the "API-backed, always" principle in the phase plan.
//!
//! Lands in Phase 3, work item 4, grouped as the Apple client groups the
//! endpoints: addresses, folders, messages, operations, compose, state.

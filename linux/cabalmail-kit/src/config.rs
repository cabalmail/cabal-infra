//! Layered user configuration: the `Settings` schema, its sync scopes, and the
//! `config.toml` reader/writer.
//!
//! Lands in Phase 1, work item 3 — before anything reads a setting, so that
//! precedence and provenance are never retrofitted. The propagation machinery
//! that points three writers at this store (file watching, debounce, server
//! push/pull) is Phase 6.
//!
//! Not to be confused with the *deployment descriptor* (`Deployment`, Phase 3),
//! which is fetched from `https://{control_domain}/config.json` and owned by
//! the deployment rather than the user.

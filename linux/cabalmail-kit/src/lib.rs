//! Shared core of the Cabalmail Linux client.
//!
//! Everything that can be decided without a widget lives here: configuration,
//! authentication, the API client, models, MIME handling, caches, compose
//! logic, the outbox, and the pure policy types that encode UI decisions.
//!
//! The crate has **no GUI dependency** — no GTK, no libadwaita, no WebKit — so
//! its tests run without a display server. That is a structural guarantee, not
//! a convention: keep it that way.
//!
//! Modules land per the phase plan in `docs/1.1.x/linux-client-plan.md`; this
//! is the workspace scaffolding only (Phase 1, work item 1).

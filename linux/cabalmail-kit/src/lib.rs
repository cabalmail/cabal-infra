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
//! Modules land per the phase plan in `docs/1.1.x/linux-client-plan.md`; each
//! stub below says which work item fills it in. They are single files until
//! they need submodules, at which point the file becomes `<name>/mod.rs`'s
//! directory sibling — the plan's layout diagram shows the destination, not a
//! requirement to create empty directories now.

pub mod api;
pub mod auth;
pub mod cache;
pub mod compose;
pub mod config;
pub mod error;
pub mod mime;
pub mod models;
pub mod outbox;
pub mod policy;
pub mod prefs;
pub mod secret;

// The error taxonomy is the one type every other module returns, so it is
// re-exported at the root: `cabalmail_kit::CabalmailError`, matching how the
// Apple client's `CabalmailError` reads at call sites.
pub use error::{AuthFailure, CabalmailError, Disposition, Result};

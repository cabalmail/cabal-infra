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

/// What `cabalmail --self-test` prints on the run that reached a main window,
/// and the only thing `cargo xtask smoke` accepts as proof that it did.
///
/// It lives here rather than in either of them because neither can see the
/// other: the app crate prints it and the build tooling greps for it, and a
/// reworded message on one side would leave the other matching nothing and
/// reporting success forever after. Both read this constant, so there is one
/// string and it cannot be edited from one end.
pub const SELF_TEST_MARKER: &str = "cabalmail: self-test reached a main window";

// The error taxonomy is the one type every other module returns, so it is
// re-exported at the root: `cabalmail_kit::CabalmailError`, matching how the
// Apple client's `CabalmailError` reads at call sites.
pub use error::{AuthFailure, CabalmailError, Disposition, Result};

//! Widgets.
//!
//! One module per surface, per the phase plan's layout: `auth` (Phase 3),
//! `mail` (Phase 4), `compose` (Phase 5), `addresses`, `folders`, and
//! `settings` (Phase 6). The shell's window is what exists now.
//!
//! UI *decisions* — when the split view collapses, which toolbar actions
//! appear, whether closing a compose window saves or discards — do not live
//! here. They are pure functions in `cabalmail-kit`'s `policy` module, tested
//! without a display. Anything in this directory that could be decided without
//! a widget is in the wrong crate.

pub mod window;

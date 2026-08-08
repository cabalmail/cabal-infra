//! Pure UI decisions, extracted so they can be tested without a display
//! server: when the split view collapses, which toolbar actions appear, how
//! list rows keep identity across a refresh, what closing a compose window
//! offers, Archive vs Trash per folder, remote-content rewriting, filter-pill
//! counts, and which folder a cross-folder search hit came from.
//!
//! The specification for this module is the file list of
//! `apple/CabalmailTests/`, whose 24 files test exactly these types. Anything
//! here that turns out to need a `gtk::Widget` has been modelled wrong.
//!
//! Populated from Phase 2 onward, alongside the UI that consumes each policy.

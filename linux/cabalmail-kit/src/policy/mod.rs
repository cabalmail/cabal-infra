//! Pure UI decisions, extracted so they can be tested without a display
//! server: when the split view collapses, which toolbar actions appear, how
//! list rows keep identity across a refresh, what closing a compose window
//! offers, Archive vs Trash per folder, remote-content rewriting, filter-pill
//! counts, and which folder a cross-folder search hit came from.
//!
//! Each module ports one pure type from `apple/CabalmailTests/`, which is a
//! much larger suite over many more types; this is the subset the plan names.
//! Anything here that turns out to need a `gtk::Widget` has been modelled
//! wrong.
//!
//! Every function here takes the fields it decides on rather than a model
//! type. That is what lets the layer land ahead of the models in Phase 3, and
//! it is also the property being asserted: a policy that needed an `Envelope`
//! would be a policy that could not be exercised from a test without building
//! one.

pub mod compose_cancel;
pub mod dispose;
pub mod html_rewrite;
pub mod layout;
pub mod pills;
pub mod reader;
pub mod row_identity;
pub mod search_source;

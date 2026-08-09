//! The on-disk send queue: entries under `$XDG_DATA_HOME/cabalmail/`, bounded
//! retries, and draining on connectivity restore.
//!
//! Lands in Phase 5, work item 5. What gets queued rather than surfaced is
//! [`crate::CabalmailError::disposition`] — the reason that distinction is
//! modelled in Phase 1 rather than discovered here.

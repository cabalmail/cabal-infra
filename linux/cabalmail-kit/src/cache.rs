//! On-disk caches under `$XDG_CACHE_HOME/cabalmail/`: per-folder envelopes
//! keyed by UIDVALIDITY, and raw `.eml` bodies evicted LRU by mtime past a
//! configurable cap.
//!
//! Lands in Phase 3, work item 5. Everything here must be safe to delete at
//! any moment.

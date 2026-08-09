//! Composition logic with no widget in sight: `Draft`, the reply builder, the
//! signature formatter, `mailto:` parsing, and the four-way body table that
//! decides what `text/plain` and `text/html` a message ships.
//!
//! Lands in Phase 5. The body table is ported verbatim from the React
//! composer's `computeMessageBodies()`, and the test asserting byte-identical
//! output for a shared corpus is the highest-value regression guard in that
//! phase.

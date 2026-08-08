//! RFC 2047 header decoding, multipart walking, attachment descriptors, and
//! `cid:` inline-image resolution.
//!
//! Lands in Phase 3, work item 5. Bodies are fetched whole and parsed here:
//! the API exposes no `fetchPart`.

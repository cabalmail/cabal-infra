//! Wire and domain types: `Envelope` (including the threading identity),
//! `Message`, `Address`, `Folder`, `FolderTree`, `Flags`, `AuthResults`, and
//! the search query/result pair.
//!
//! Lands in Phase 3, work item 5. Types are defined fresh rather than shared
//! with Apple, Android, or the web app — the contract is the endpoint shapes,
//! not the code.

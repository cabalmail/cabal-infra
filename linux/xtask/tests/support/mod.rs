//! Files these tests read from outside the `linux/` workspace.
//!
//! A test that reads across the tree only works while the workflow that runs
//! it fires on changes to what it reads. `linux.yml` triggers on `linux/**`,
//! so a contract test pointed at `lambda/` or `react/` is silent exactly when
//! it matters: the other tree changes, this workflow does not run, the change
//! merges green, and the divergence surfaces later on somebody's unrelated
//! push to `linux/`.
//!
//! Every such file is registered here, and `workflow_contract.rs` asserts the
//! workflow's `paths:` filter covers all of them. Reading one goes through
//! `repo_input`, which refuses a path that is not registered — so a new
//! cross-tree test cannot be written without the trigger being extended in the
//! same change.

#![allow(dead_code)]

use std::path::{Path, PathBuf};

/// Repository-relative paths, outside `linux/`, that a test in this crate
/// reads. Adding one here means adding it to `linux.yml`'s `paths:` filter.
pub const REPO_INPUTS: &[&str] = &[
    // The synced-preference contract: the client's key table against the
    // Lambda's APP_ALLOWED set.
    "lambda/api/set_preferences/function.py",
    // The composer's marked and turndown pins, which the Arch PKGBUILD has to
    // carry verbatim. Dependabot bumps them here.
    "react/admin/package-lock.json",
    // The licence the Arch package installs.
    "LICENSE.md",
];

pub fn repo_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .and_then(Path::parent)
        .expect("the workspace lives inside the repository")
        .to_path_buf()
}

/// The absolute path of a registered cross-tree input.
///
/// Panics for anything unregistered rather than reading it: an unregistered
/// file is one the workflow does not fire on, and a test over a file nobody
/// watches is a test that reports the drift it exists to catch on the wrong
/// push, or never.
pub fn repo_input(relative: &str) -> PathBuf {
    assert!(
        REPO_INPUTS.contains(&relative),
        "`{relative}` is not registered in tests/support/mod.rs. A test that \
         reads outside linux/ needs an entry there and a matching entry in \
         linux.yml's paths: filter, or it cannot fire when that file changes."
    );
    repo_root().join(relative)
}

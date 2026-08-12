//! `cargo xtask sync-vendored` — materialize marked and turndown into the
//! composer's resource directory.
//!
//! The work is in `scripts/sync-vendored.sh`, mirroring
//! `apple/scripts/sync-vendored.sh`. Keeping the implementation in shell is
//! what lets a packaging container or a CI step run it without building the
//! workspace first; this subcommand exists so there is one spelling to
//! document, and so `cargo xtask ci` could grow the step without anyone having
//! to remember the path.

use std::path::Path;

use crate::process::{self, Step};

/// The script, relative to the `linux/` workspace root.
pub const SCRIPT: &str = "scripts/sync-vendored.sh";

pub fn run(workspace: &Path) -> Result<(), String> {
    let script = workspace.join(SCRIPT);
    if !script.is_file() {
        return Err(format!("{} is missing", script.display()));
    }
    let step = Step::new(
        "sync-vendored",
        script.to_string_lossy().into_owned(),
        Vec::<&str>::new(),
    );
    process::run(&step, workspace)
}

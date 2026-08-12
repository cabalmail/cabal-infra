//! Guards on `scripts/sync-vendored.sh`, which `cargo xtask sync-vendored`
//! wraps.
//!
//! The script copies upstream bytes into the source tree. Two things about it
//! are worth pinning: those bytes must never be committed, and their versions
//! must keep coming from `react/admin/package.json`, which is where the pins
//! live and where Dependabot bumps them. A file added to the script without a
//! matching `.gitignore` entry is how a vendored bundle quietly becomes a
//! committed one, so that pairing is asserted rather than trusted.

use std::path::{Path, PathBuf};

fn linux_dir() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("xtask lives inside the workspace root")
        .to_path_buf()
}

fn script_path() -> PathBuf {
    linux_dir().join("scripts/sync-vendored.sh")
}

fn script() -> String {
    let path = script_path();
    std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("reading {}: {e}", path.display()))
}

/// The destination directory, relative to `linux/`, read out of the script's
/// `DEST_DIR=` assignment so the test cannot disagree with the script about
/// where the files land.
fn destination(script: &str) -> String {
    let line = script
        .lines()
        .find(|line| line.starts_with("DEST_DIR="))
        .expect("the script assigns DEST_DIR");
    line.trim_start_matches("DEST_DIR=")
        .trim_matches('"')
        .trim_start_matches("$LINUX_DIR/")
        .to_owned()
}

/// Every file the script writes into that directory.
fn copied_files(script: &str) -> Vec<String> {
    let mut files: Vec<String> = script
        .match_indices("$DEST_DIR/")
        .map(|(at, marker)| {
            let rest = &script[at + marker.len()..];
            let end = rest
                .find('"')
                .expect("a destination path is inside double quotes");
            rest[..end].to_owned()
        })
        .collect();
    files.sort();
    files.dedup();
    files
}

#[test]
fn the_script_xtask_wraps_exists_and_is_executable() {
    let path = script_path();
    assert!(path.is_file(), "{} is missing", path.display());

    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt as _;
        let mode = std::fs::metadata(&path)
            .expect("the script is readable")
            .permissions()
            .mode();
        assert!(
            mode & 0o111 != 0,
            "{} is not executable (mode {mode:o})",
            path.display()
        );
    }
}

/// The repo-wide shell convention, and it matters here: a failed `cp` that
/// carries on leaves a half-populated resource directory that the build then
/// bundles.
#[test]
fn the_script_fails_on_the_first_error() {
    assert!(script().contains("set -euo pipefail"));
}

/// `react/admin/package.json` is the single source of truth for the marked and
/// turndown versions across all three clients. A script that fetched them from
/// anywhere else would take the Linux composer out of Dependabot's reach.
#[test]
fn the_versions_still_come_from_the_react_manifest() {
    let script = script();
    assert!(
        script.contains("react/admin"),
        "the script no longer reads from react/admin"
    );
    for module in ["node_modules/marked", "node_modules/turndown"] {
        assert!(
            script.contains(module),
            "the script no longer copies {module}"
        );
    }
}

/// The pairing that actually rots: a fifth vendored file added to the script
/// without an ignore line for it.
#[test]
fn every_file_the_script_writes_is_gitignored() {
    let script = script();
    let dest = destination(&script);
    let files = copied_files(&script);
    assert!(!files.is_empty(), "the script copies nothing");

    let ignored =
        std::fs::read_to_string(linux_dir().join(".gitignore")).expect(".gitignore reads");
    for file in files {
        let entry = format!("/{dest}/{file}");
        assert!(
            ignored.lines().any(|line| line.trim() == entry),
            "linux/.gitignore does not ignore `{entry}`, which sync-vendored.sh writes"
        );
    }
}

/// Vendored bytes are materialized, never committed — the check that catches
/// someone running the script and then `git add -A`.
#[test]
fn no_vendored_bundle_is_committed() {
    let script = script();
    let dest = linux_dir().join(destination(&script));
    for file in copied_files(&script) {
        let path = dest.join(&file);
        if !path.exists() {
            continue;
        }
        let tracked = std::process::Command::new("git")
            .args(["ls-files", "--error-unmatch"])
            .arg(&path)
            .current_dir(linux_dir())
            .output();
        if let Ok(output) = tracked {
            assert!(
                !output.status.success(),
                "{} is committed; it should be materialized by sync-vendored.sh",
                path.display()
            );
        }
    }
}

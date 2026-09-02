//! `cabalmail-kit` has no GUI dependency, transitively.
//!
//! This is the structural decision the whole test story rests on: the kit
//! compiles and tests with no GTK, no libadwaita, no WebKit, and therefore no
//! display server, which is what lets the bulk of the suite run in seconds on a
//! bare runner. `workspace_invariants.rs` catches the direct case — a GUI crate
//! typed into the kit's own manifest. This catches the one nobody would type on
//! purpose: a plain-looking dependency that pulls GTK in three levels down.
//!
//! The tree is asked of cargo rather than reconstructed from `Cargo.lock`,
//! because cargo is what resolves features and target-specific edges. `--locked`
//! so a stale lock fails here rather than being quietly rewritten.

use std::path::{Path, PathBuf};
use std::process::Command;

fn linux_dir() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("xtask lives inside the workspace root")
        .to_path_buf()
}

/// Every crate in `package`'s dependency tree, by name.
///
/// `--edges normal,build,dev` because a GUI crate arriving as a dev-dependency
/// would still need a display to run the tests, and one arriving as a build
/// dependency would still need the system libraries installed. `--no-dedupe` so
/// a crate reached by two paths is not printed once and elided elsewhere.
fn dependency_tree(package: &str) -> Vec<String> {
    let output = Command::new(std::env::var("CARGO").unwrap_or_else(|_| "cargo".to_owned()))
        .args([
            "tree",
            "--locked",
            "-p",
            package,
            "--edges",
            "normal,build,dev",
            "--prefix",
            "none",
            "--no-dedupe",
        ])
        .current_dir(linux_dir())
        .output()
        .expect("running `cargo tree`");
    assert!(
        output.status.success(),
        "`cargo tree -p {package}` failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );

    let names: Vec<String> = String::from_utf8(output.stdout)
        .expect("cargo tree prints UTF-8")
        .lines()
        .filter_map(|line| line.split_whitespace().next())
        .filter(|name| !name.is_empty())
        .map(str::to_owned)
        .collect();

    // A tree that came back empty, or without the package that was asked for,
    // would pass every assertion below having examined nothing.
    assert!(
        names.iter().any(|name| name == package),
        "`cargo tree -p {package}` did not print {package} itself; the output \
         format has changed and this check is examining nothing"
    );
    names
}

/// Whether a crate name is part of the GUI stack. Substrings rather than an
/// exact list, so `gtk4-sys`, `libadwaita-sys`, and a future `webkit7` are all
/// caught without an edit. `glib` and `gio` are deliberately not here: they are
/// GLib, not a toolkit, and the kit is free to grow one if it ever needs it.
fn is_gui_crate(name: &str) -> bool {
    let lowered = name.to_lowercase();
    ["gtk", "adw", "webkit"]
        .iter()
        .any(|marker| lowered.contains(marker))
}

fn gui_crates(package: &str) -> Vec<String> {
    let mut found: Vec<String> = dependency_tree(package)
        .into_iter()
        // The app crate is `cabalmail-gtk`. It is the thing being asked about,
        // not something it depends on.
        .filter(|name| name != package && is_gui_crate(name))
        .collect();
    found.sort();
    found.dedup();
    found
}

#[test]
fn the_kit_pulls_in_no_gui_crate_at_any_depth() {
    let found = gui_crates("cabalmail-kit");
    assert!(
        found.is_empty(),
        "cabalmail-kit now depends on {}. That crate needs a display server to \
         test against, which is the one thing the kit is defined not to need. \
         The dependency that pulled it in is the one to change, not this test.",
        found.join(", ")
    );
}

/// The proof that the check above is not passing for the wrong reason. Run the
/// same scan over the crate that *does* use GTK: if it comes back clean, the
/// scan is broken — a renamed flag, a changed output format, a predicate that
/// stopped matching — and the kit's result meant nothing.
#[test]
fn the_same_scan_finds_the_gui_crates_the_app_really_has() {
    let found = gui_crates("cabalmail-gtk");
    assert!(
        !found.is_empty(),
        "the scan found no GUI crate in cabalmail-gtk, which is built on GTK4 \
         and libadwaita. It is the scan that is broken, not the app."
    );
}

#[test]
fn the_toolkit_is_recognised_and_glib_is_not() {
    for name in [
        "gtk4",
        "gtk4-sys",
        "libadwaita",
        "libadwaita-sys",
        "webkit6",
    ] {
        assert!(is_gui_crate(name), "`{name}` should read as a GUI crate");
    }
    for name in ["glib", "gio", "gdk-pixbuf", "serde", "tokio"] {
        assert!(
            !is_gui_crate(name),
            "`{name}` should not read as a GUI crate"
        );
    }
}

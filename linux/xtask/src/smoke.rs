//! `cargo xtask smoke` — install the built package, launch what it installed,
//! and assert the client reaches a main window.
//!
//! The only check in the gate that exercises the *packaged artifact*. Every
//! other step builds from the working tree, so none of them can see a
//! GResource that never got bundled, a data file the package forgot to
//! install, or a shared library the dependency array does not name. This
//! installs the package into the container's own root, runs
//! `/usr/bin/cabalmail --self-test` under whatever display is going, and reads
//! the marker the client prints on the run that reached a window.
//!
//! It is not a `ci` step. Installing a package into the root filesystem is not
//! something a developer should have happen on a pre-push gate, and it needs a
//! throwaway container to be worth anything.

use std::path::{Path, PathBuf};
use std::process::Command;

use crate::process::{self, Step};

/// Where `cargo xtask package arch` leaves what it built.
const STAGING: &str = "target/package/arch";

/// What the package installs, and what this runs.
const INSTALLED_BINARY: &str = "/usr/bin/cabalmail";

/// What the client prints on the run that reached a main window, and the only
/// thing this accepts as proof that it did.
///
/// A copy of `SELF_TEST_MARKER` rather than a use of it: taking
/// the kit as a real dependency would put its dependency tree — `reqwest` and
/// `oo7` from Phase 3 — into every container that runs any `cargo xtask`
/// subcommand, including the smoke container, which installs nothing but a
/// toolchain. `the_marker_matches_the_one_the_client_prints` holds the two
/// copies together, the same way the tool pins are held.
const SELF_TEST_MARKER: &str = "cabalmail: self-test reached a main window";

/// Installs `package` and runs it.
///
/// `package` may be the package file, or a directory holding one — which is
/// what the workflow passes, having downloaded the artifact `package-arch`
/// uploaded. Without it, the staging directory the last `package arch` wrote
/// to.
pub fn run(workspace: &Path, package: Option<&str>) -> Result<(), String> {
    let package = resolve(workspace, package)?;

    require_root()?;
    process::run(
        &Step::new(
            "install",
            "pacman",
            ["-U", "--noconfirm", &package.to_string_lossy()],
        ),
        workspace,
    )?;

    // A throwaway home, so the run reads the configuration an install starts
    // with rather than whatever is in the caller's. A smoke test that passed
    // because of a developer's config.toml would be worth nothing.
    let home = throwaway_home()?;
    let launch = launch_command(has_display());
    println!("[xtask] smoke: {}", INSTALLED_BINARY);
    let output = Command::new(&launch[0])
        .args(&launch[1..])
        .env("HOME", &home)
        .env("XDG_CONFIG_HOME", home.join("config"))
        .env("XDG_DATA_HOME", home.join("data"))
        .env("XDG_CACHE_HOME", home.join("cache"))
        .output()
        .map_err(|e| format!("could not run `{}`: {e}", launch[0]))?;

    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    print!("{stdout}");
    eprint!("{stderr}");
    let _ = std::fs::remove_dir_all(&home);

    if !output.status.success() {
        return Err(format!(
            "the installed client exited {} rather than starting",
            output.status
        ));
    }
    if !stdout.contains(SELF_TEST_MARKER) {
        return Err(format!(
            "the installed client exited 0 without printing `{}`, so nothing \
             here saw it reach a window",
            SELF_TEST_MARKER
        ));
    }
    println!(
        "[xtask] smoke: {} started and drew a window",
        package.display()
    );
    Ok(())
}

/// How the installed binary is launched. `xvfb-run -a` where there is no
/// session, which is every container this runs in; `-a` picks a free server
/// number, which matters on a runner where two jobs can overlap.
fn launch_command(has_display: bool) -> Vec<String> {
    let mut command: Vec<String> = if has_display {
        Vec::new()
    } else {
        vec!["xvfb-run".to_owned(), "-a".to_owned()]
    };
    command.push(INSTALLED_BINARY.to_owned());
    command.push("--self-test".to_owned());
    command
}

fn has_display() -> bool {
    let running = |name: &str| std::env::var_os(name).is_some_and(|value| !value.is_empty());
    running("WAYLAND_DISPLAY") || running("DISPLAY")
}

/// This installs a package into the root filesystem, which needs root and is
/// why it runs in a container rather than on anybody's machine. `package arch`
/// refuses root for the opposite reason; saying which way round each one goes
/// is cheaper than reading pacman's message and guessing.
fn require_root() -> Result<(), String> {
    if process::running_as_root()? {
        return Ok(());
    }
    Err(
        "installing the package needs root, so this does too. It is meant for a \
         throwaway container: `cargo xtask package arch` builds the package as an \
         unprivileged user, and this installs it as root."
            .to_owned(),
    )
}

/// The package to install, from what was asked for.
///
/// A file is taken as the package. Anything else is read as a directory
/// holding one — including a path that does not exist, because the default is
/// a staging directory that only exists once `package arch` has run, and
/// "`target/package/arch` is not a file" is a worse answer than the one
/// [`main_package_in`] gives. A *named* path that is neither says so, rather
/// than being reported as an empty directory.
fn resolve(workspace: &Path, package: Option<&str>) -> Result<PathBuf, String> {
    let given = package.map_or_else(|| workspace.join(STAGING), PathBuf::from);
    if given.is_file() {
        return Ok(given);
    }
    if package.is_some() && !given.is_dir() {
        return Err(format!(
            "{} is neither a package nor a directory holding one",
            given.display()
        ));
    }
    main_package_in(&given)
}

/// The one installable package in `directory`.
///
/// makepkg's separate debug-symbol package is skipped: installing it would
/// succeed and install no binary, and the failure would read as a broken
/// client rather than as the wrong file.
fn main_package_in(directory: &Path) -> Result<PathBuf, String> {
    let entries = std::fs::read_dir(directory).map_err(|e| {
        format!(
            "reading {}: {e}. `cargo xtask package arch` builds what this installs.",
            directory.display()
        )
    })?;

    let mut found: Vec<PathBuf> = Vec::new();
    for entry in entries {
        let name = entry
            .map_err(|e| format!("reading {}: {e}", directory.display()))?
            .file_name();
        if crate::package::is_main_package(&name.to_string_lossy()) {
            found.push(directory.join(&name));
        }
    }
    found.sort();

    match found.len() {
        1 => Ok(found.remove(0)),
        0 => Err(format!(
            "no package in {}. Run `cargo xtask package arch` first, or name one.",
            directory.display()
        )),
        _ => Err(format!(
            "{} packages in {}: {}. Name the one to install.",
            found.len(),
            directory.display(),
            found
                .iter()
                .map(|path| path.display().to_string())
                .collect::<Vec<_>>()
                .join(", ")
        )),
    }
}

/// A home directory this run owns, removed when it is done.
///
/// In the system temp directory, not under `target/`: it is not a build
/// artifact, and the checkout is routinely mounted read-only — which is how
/// this is run against a container, and how the defect that put it there was
/// found. Keyed on the process id so two runs on one machine do not delete
/// each other's.
fn throwaway_home() -> Result<PathBuf, String> {
    let path = std::env::temp_dir().join(format!("cabalmail-smoke-home-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&path);
    std::fs::create_dir_all(&path).map_err(|e| format!("creating {}: {e}", path.display()))?;
    Ok(path)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Every container this runs in is headless, so the wrapper is the case
    /// that matters. Without it the client fails to open a display and the job
    /// reports a packaging break that is really a missing Xvfb.
    #[test]
    fn a_headless_run_is_wrapped_in_xvfb() {
        assert_eq!(
            launch_command(false),
            vec!["xvfb-run", "-a", INSTALLED_BINARY, "--self-test"]
        );
    }

    /// A developer with a session gets the real one: wrapping it would hide
    /// the client behind a virtual display they cannot see.
    #[test]
    fn a_session_in_hand_launches_the_binary_directly() {
        assert_eq!(launch_command(true), vec![INSTALLED_BINARY, "--self-test"]);
    }

    /// The client prints this and nothing else proves it started. A reworded
    /// message on one side would leave this matching nothing and reporting
    /// success forever after, which is why the copy is held rather than
    /// trusted.
    #[test]
    fn the_marker_matches_the_one_the_client_prints() {
        assert_eq!(SELF_TEST_MARKER, cabalmail_kit::SELF_TEST_MARKER);
    }

    /// The checkout is mounted read-only when this runs against a container,
    /// so nothing it needs to write may live under the workspace.
    #[test]
    fn the_throwaway_home_is_outside_the_checkout() {
        let home = throwaway_home().expect("a scratch home");
        assert!(home.starts_with(std::env::temp_dir()), "{}", home.display());
        assert!(home.is_dir());
        let _ = std::fs::remove_dir_all(&home);
    }

    /// The binary this launches is the one the package installs. A path that
    /// drifted would run the developer's `cargo build` output, or nothing.
    #[test]
    fn the_binary_is_the_installed_one_rather_than_a_built_one() {
        assert!(INSTALLED_BINARY.starts_with('/'));
        for launch in [launch_command(true), launch_command(false)] {
            assert!(
                launch.iter().any(|word| word == INSTALLED_BINARY),
                "{launch:?} does not run the installed binary"
            );
        }
    }

    /// A scratch directory holding `names`, cleaned up by the caller. Keyed on
    /// the process id as well as the label, so two runs on one machine do not
    /// delete each other's fixtures out from under them.
    fn directory_of(label: &str, names: &[&str]) -> PathBuf {
        let path =
            std::env::temp_dir().join(format!("cabalmail-smoke-{label}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&path);
        std::fs::create_dir_all(&path).expect("a scratch directory");
        for name in names {
            std::fs::write(path.join(name), b"").expect("a scratch file");
        }
        path
    }

    /// The failure a developer is most likely to hit, asked the way they ask
    /// it: `cargo xtask smoke` in a checkout that has never packaged
    /// anything, where the staging directory does not exist at all. Going
    /// through `resolve` rather than the helper is the point — the helper's
    /// message is worth nothing if the path a user takes never reaches it.
    #[test]
    fn no_package_says_what_builds_one() {
        let empty = directory_of("empty", &[]);
        let error = resolve(&empty, None).expect_err("nothing was built");
        assert!(error.contains("cargo xtask package arch"), "{error}");
        let _ = std::fs::remove_dir_all(&empty);

        let never_packaged = directory_of("never-packaged", &[]);
        let error = resolve(&never_packaged.join("no-such-checkout"), None)
            .expect_err("nothing was ever built here");
        assert!(error.contains("cargo xtask package arch"), "{error}");
        let _ = std::fs::remove_dir_all(&never_packaged);
    }

    /// A package named outright is used as given, without a directory scan.
    #[test]
    fn a_named_package_is_the_one_installed() {
        let staging = directory_of("named", &["cabalmail-1.1.0-1-x86_64.pkg.tar.zst"]);
        let named = staging.join("cabalmail-1.1.0-1-x86_64.pkg.tar.zst");
        assert_eq!(
            resolve(Path::new("/unused"), Some(&named.to_string_lossy())),
            Ok(named.clone())
        );
        let _ = std::fs::remove_dir_all(&staging);
    }

    /// A typo'd package path reads as a typo, not as an empty directory.
    #[test]
    fn a_named_path_that_is_neither_says_so() {
        let error = resolve(
            Path::new("/unused"),
            Some("/nonexistent/cabalmail.pkg.tar.zst"),
        )
        .expect_err("no such package");
        assert!(
            error.contains("neither a package nor a directory"),
            "{error}"
        );
    }

    /// makepkg writes a debug-symbol package beside the real one under the
    /// stock configuration. Installing that one succeeds and installs no
    /// binary, so the run would fail as a broken client rather than as the
    /// wrong file.
    #[test]
    fn the_debug_package_is_not_the_one_installed() {
        let staging = directory_of(
            "debug",
            &[
                "cabalmail-1.1.0-1-x86_64.pkg.tar.zst",
                "cabalmail-debug-1.1.0-1-x86_64.pkg.tar.zst",
                ".SRCINFO",
            ],
        );
        let chosen = main_package_in(&staging).expect("one installable package");
        assert_eq!(
            chosen.file_name().and_then(|name| name.to_str()),
            Some("cabalmail-1.1.0-1-x86_64.pkg.tar.zst")
        );
        let _ = std::fs::remove_dir_all(&staging);
    }

    /// Two real packages is an ambiguity, not a reason to guess: a stale one
    /// from an earlier version installs an older client and reports success.
    #[test]
    fn two_packages_are_an_ambiguity_rather_than_a_guess() {
        let staging = directory_of(
            "ambiguous",
            &[
                "cabalmail-1.1.0-1-x86_64.pkg.tar.zst",
                "cabalmail-1.0.0-1-x86_64.pkg.tar.zst",
            ],
        );
        let error = main_package_in(&staging).expect_err("two packages");
        assert!(error.contains("Name the one to install"), "{error}");
        let _ = std::fs::remove_dir_all(&staging);
    }
}

//! `cargo xtask package <distro>` — build a distribution package and lint it.
//!
//! Arch is the only distribution this builds today; Debian and RPM land in
//! Phase 8 and are declared here so asking for one gets an answer about which
//! work item owns it.
//!
//! The PKGBUILD in `packaging/arch/` is what an AUR consumer builds, tag and
//! all. This builds the *working tree* from the same file, by staging a copy
//! with two substitutions: `pkgver` comes from the tree's own description, and
//! the git source points at the local checkout. Nothing else is touched, so a
//! break in the dependency arrays, the pinned JavaScript, or any build step
//! fails on the push that caused it rather than at release time.

use std::path::{Path, PathBuf};
use std::process::Command;

use crate::process::{self, Step};

/// What `packaging/arch/PKGBUILD` calls itself. Stated here because the built
/// file names are matched against it; a test holds the two together.
const PKGNAME: &str = "cabalmail";

/// The distributions `package` knows about, and what answers for each.
const DISTROS: &[(&str, Option<&str>)] = &[
    ("arch", None),
    ("deb", Some("Phase 8, Debian and Ubuntu packaging")),
    ("rpm", Some("Phase 8, Fedora and RHEL packaging")),
];

/// The distribution names, for a usage message.
pub fn distro_names() -> Vec<&'static str> {
    DISTROS.iter().map(|(name, _)| *name).collect()
}

/// The work item that implements `distro`, or `None` if it is built today.
/// `Err` if the name is not one this subcommand knows.
pub fn pending_work_item(distro: &str) -> Result<Option<&'static str>, String> {
    DISTROS
        .iter()
        .find(|(name, _)| *name == distro)
        .map(|(_, work_item)| *work_item)
        .ok_or_else(|| {
            format!(
                "no packaging for `{distro}`. Distributions: {}",
                distro_names().join(", ")
            )
        })
}

/// Builds the Arch package from the working tree and lints it.
pub fn arch(workspace: &Path) -> Result<(), String> {
    refuse_to_run_as_root()?;

    let repository = workspace
        .parent()
        .ok_or("the workspace has no parent repository")?;
    let commit = git(repository, &["rev-parse", "HEAD"])?;
    if !git(repository, &["status", "--porcelain"])?.is_empty() {
        eprintln!(
            "[xtask] package: the working tree has uncommitted changes. makepkg \
             builds from git, so this packages {} and nothing that is not \
             committed.",
            short(&commit)
        );
    }

    let pkgver = pkgver_from_describe(&describe(repository)?)?;
    let staging = workspace.join("target/package/arch");
    std::fs::create_dir_all(&staging)
        .map_err(|e| format!("creating {}: {e}", staging.display()))?;

    let source = workspace.join("packaging/arch/PKGBUILD");
    let text = std::fs::read_to_string(&source)
        .map_err(|e| format!("reading {}: {e}", source.display()))?;
    let staged = stage_pkgbuild(&text, &pkgver, repository, &commit)?;
    let staged_path = staging.join("PKGBUILD");
    std::fs::write(&staged_path, staged)
        .map_err(|e| format!("writing {}: {e}", staged_path.display()))?;
    println!("[xtask] package: building {pkgver} from {}", short(&commit));

    // Last run's package, if the version moved on. Leaving it there would make
    // "which one did makepkg just write?" a guess.
    for stale in packages_in(&staging)? {
        std::fs::remove_file(staging.join(&stale))
            .map_err(|e| format!("removing {}: {e}", stale.display()))?;
    }

    // `-f` so a rebuild replaces the package from the last run; dependency
    // checking is left on, because a missing blueprint-compiler should stop
    // the run with makepkg's own message rather than fail deep inside build().
    process::run(
        &Step::new("makepkg", "makepkg", ["--force", "--noconfirm"]),
        &staging,
    )?;

    let package = built_package(&staging, PKGNAME, &pkgver)?;
    lint(&staging, Path::new("PKGBUILD"))?;
    lint(&staging, &package)?;
    for artifact in packages_in(&staging)? {
        println!("[xtask] package: {}", staging.join(&artifact).display());
    }
    Ok(())
}

/// makepkg refuses to run as root, and its message arrives after the staging
/// work is already done. Saying so first — and saying what to do instead — is
/// the difference between a readable CI log and a puzzle.
fn refuse_to_run_as_root() -> Result<(), String> {
    use std::os::unix::fs::MetadataExt as _;

    // /proc/self is owned by the process's own uid, which is the cheapest way
    // to ask without taking a dependency for one call.
    let uid = std::fs::metadata("/proc/self")
        .map_err(|e| format!("reading /proc/self: {e}"))?
        .uid();
    if uid == 0 {
        return Err(
            "makepkg refuses to run as root, so this does too. Run it as \
                    an unprivileged user with the dependencies from \
                    packaging/deps/arch.txt already installed."
                .to_owned(),
        );
    }
    Ok(())
}

/// `git describe` against the release tags, which are bare semver — the same
/// tags `scripts/promote.sh` cuts, and the version source of truth.
fn describe(repository: &Path) -> Result<String, String> {
    git(
        repository,
        &[
            "describe",
            "--tags",
            "--long",
            "--match",
            "[0-9]*.[0-9]*.[0-9]*",
        ],
    )
    .map_err(|e| {
        format!(
            "{e}\nThe package version comes from the latest release tag. A \
             checkout without tags cannot supply one: `git fetch --tags`, or \
             `fetch-depth: 0` in a workflow."
        )
    })
}

/// A tree build's `pkgver`, from `git describe --long`: `1.5.0-3-gabc1234`
/// becomes `1.5.0.r3.gabc1234`. pacman's version comparison reads that as
/// later than `1.5.0` and earlier than `1.5.1`, which is what a build three
/// commits past a tag is.
///
/// Hyphens are not merely discouraged in a `pkgver` — makepkg splits the
/// package file name on them.
fn pkgver_from_describe(describe: &str) -> Result<String, String> {
    let mut parts = describe.trim().rsplitn(3, '-');
    let object = parts.next().unwrap_or_default();
    let distance = parts.next().unwrap_or_default();
    let tag = parts.next().unwrap_or_default();
    if tag.is_empty() || distance.is_empty() || !object.starts_with('g') {
        return Err(format!(
            "`{describe}` is not `<tag>-<distance>-g<object>` as \
             `git describe --long` produces"
        ));
    }
    Ok(format!("{tag}.r{distance}.{object}"))
}

/// The two substitutions that turn the published PKGBUILD into one that builds
/// this checkout. Everything else about the file is what an AUR consumer gets,
/// which is the whole point of building the same file rather than a second one
/// kept alongside it.
fn stage_pkgbuild(
    pkgbuild: &str,
    pkgver: &str,
    repository: &Path,
    commit: &str,
) -> Result<String, String> {
    let mut versions = 0;
    let mut sources = 0;
    let mut staged = String::with_capacity(pkgbuild.len() + STAGED_HEADER.len());
    staged.push_str(STAGED_HEADER);

    for line in pkgbuild.lines() {
        if line.starts_with("pkgver=") {
            versions += 1;
            staged.push_str(&format!("pkgver={pkgver}\n"));
            continue;
        }
        match line.split_once("git+") {
            Some((before, rest)) => {
                sources += 1;
                let after = rest
                    .find('"')
                    .ok_or_else(|| format!("the git source is not a quoted string: {line}"))?;
                staged.push_str(&format!(
                    "{before}git+file://{}#commit={commit}{}\n",
                    repository.display(),
                    &rest[after..]
                ));
            }
            None => {
                staged.push_str(line);
                staged.push('\n');
            }
        }
    }

    for (what, found) in [("a pkgver= line", versions), ("a git+ source", sources)] {
        if found != 1 {
            return Err(format!(
                "packaging/arch/PKGBUILD has {found} of what should be exactly \
                 one: {what}. `cargo xtask package arch` rewrites it, so the \
                 shape it rewrites has to stay recognizable."
            ));
        }
    }
    Ok(staged)
}

const STAGED_HEADER: &str = "\
# Generated by `cargo xtask package arch` from packaging/arch/PKGBUILD — edit
# that file, not this one. Two lines differ: pkgver comes from the working
# tree's `git describe`, and the git source is the local checkout at HEAD.
";

/// Every package file sitting in the staging directory.
fn packages_in(staging: &Path) -> Result<Vec<PathBuf>, String> {
    let mut found: Vec<PathBuf> = std::fs::read_dir(staging)
        .map_err(|e| format!("reading {}: {e}", staging.display()))?
        .filter_map(Result::ok)
        .map(|entry| PathBuf::from(entry.file_name()))
        .filter(|name| name.to_string_lossy().contains(".pkg.tar"))
        .collect();
    found.sort();
    Ok(found)
}

/// The package makepkg just wrote, out of everything in the staging directory.
///
/// There can legitimately be two: a build environment with `debug` in its
/// `OPTIONS` — which is what the `archlinux:base-devel` image ships, unlike a
/// stock `/etc/makepkg.conf` — splits the symbols into a second
/// `<pkgname>-debug-…` package. That one is a real artifact, not a leftover, so
/// it is named rather than counted.
fn built_package(staging: &Path, pkgname: &str, pkgver: &str) -> Result<PathBuf, String> {
    let built = packages_in(staging)?;
    let names: Vec<String> = built
        .iter()
        .map(|name| name.to_string_lossy().into_owned())
        .collect();
    choose_package(&names, pkgname, pkgver).map(PathBuf::from)
}

/// Picks the package this build produced out of the file names in hand. Pure,
/// so the cases that only arise on somebody else's makepkg.conf are testable
/// here rather than discovered in a container.
fn choose_package(names: &[String], pkgname: &str, pkgver: &str) -> Result<String, String> {
    // `<pkgname>-<pkgver>-`: `cabalmail-debug-…` does not match it, and neither
    // does a package left over from an earlier version.
    let prefix = format!("{pkgname}-{pkgver}-");
    let mut mine: Vec<&String> = names
        .iter()
        .filter(|name| name.starts_with(&prefix))
        .collect();

    match mine.len() {
        1 => Ok(mine.remove(0).clone()),
        0 => Err(format!(
            "makepkg reported success but left no `{prefix}…` package behind. \
             Found: {}",
            if names.is_empty() {
                "nothing".to_owned()
            } else {
                names.join(", ")
            }
        )),
        _ => Err(format!(
            "{} packages match `{prefix}…`: {}. Remove the stale ones and run \
             again.",
            mine.len(),
            mine.iter()
                .map(|name| name.as_str())
                .collect::<Vec<_>>()
                .join(", ")
        )),
    }
}

/// namcap, on the PKGBUILD and on the package it produced. Its warnings are
/// advice; its errors are the ones the plan asks CI to fail on, so only those
/// stop the run — and the whole report is printed either way.
fn lint(staging: &Path, target: &Path) -> Result<(), String> {
    let step = Step::new("namcap", "namcap", [target.to_string_lossy().into_owned()]);
    println!("[xtask] {}: {}", step.label, step.command_line());
    let output = Command::new(&step.program)
        .args(&step.args)
        .current_dir(staging)
        .output()
        .map_err(|e| {
            format!(
                "could not run `namcap`: {e}. It is in packaging/deps/arch.txt; \
                 `pacman -S namcap`."
            )
        })?;

    let report = String::from_utf8_lossy(&output.stdout).into_owned()
        + &String::from_utf8_lossy(&output.stderr);
    print!("{report}");
    if !output.status.success() {
        return Err(format!(
            "namcap failed ({}) on {}",
            output.status,
            target.display()
        ));
    }

    let errors = namcap_errors(&report);
    if errors.is_empty() {
        return Ok(());
    }
    Err(format!(
        "namcap reported {} error(s) on {}:\n{}",
        errors.len(),
        target.display(),
        errors.join("\n")
    ))
}

/// namcap prints one finding per line, `<package> E: <what>` for an error and
/// `W:` for a warning. Only the errors are failures.
fn namcap_errors(report: &str) -> Vec<String> {
    report
        .lines()
        .filter(|line| line.contains(" E: "))
        .map(str::to_owned)
        .collect()
}

fn git(repository: &Path, args: &[&str]) -> Result<String, String> {
    let output = Command::new("git")
        .args(args)
        .current_dir(repository)
        .output()
        .map_err(|e| format!("could not run `git {}`: {e}", args.join(" ")))?;
    if !output.status.success() {
        return Err(format!(
            "`git {}` failed ({}): {}",
            args.join(" "),
            output.status,
            String::from_utf8_lossy(&output.stderr).trim()
        ));
    }
    Ok(String::from_utf8_lossy(&output.stdout).trim().to_owned())
}

fn short(commit: &str) -> &str {
    &commit[..commit.len().min(8)]
}

#[cfg(test)]
mod tests {
    use super::*;

    const PKGBUILD: &str = "\
pkgname=cabalmail
pkgver=1.5.0
pkgrel=1
source=(\"$pkgname::git+$url.git#tag=$pkgver\"
        \"marked-1.tgz::https://example.invalid/marked-1.tgz\")
sha256sums=('SKIP' 'abc')
";

    fn staged() -> String {
        stage_pkgbuild(
            PKGBUILD,
            "1.5.0.r3.gabc1234",
            Path::new("/home/builder/cabal-infra"),
            "abc1234def",
        )
        .expect("the PKGBUILD has the shape the stager rewrites")
    }

    #[test]
    fn staging_stamps_the_working_trees_version() {
        assert!(staged().contains("\npkgver=1.5.0.r3.gabc1234\n"));
        assert!(!staged().contains("pkgver=1.5.0\n"));
    }

    /// The tag the published file names does not exist yet for an unreleased
    /// tree; the commit in hand always does.
    #[test]
    fn staging_points_the_git_source_at_the_local_checkout() {
        assert!(
            staged()
                .contains("\"$pkgname::git+file:///home/builder/cabal-infra#commit=abc1234def\"")
        );
        assert!(!staged().contains("#tag="));
    }

    /// Everything else is what an AUR consumer builds. A stager that quietly
    /// rewrote more would make CI's package and the published one different
    /// things.
    #[test]
    fn staging_changes_nothing_else() {
        let staged = staged();
        for line in PKGBUILD.lines() {
            if line.starts_with("pkgver=") || line.contains("git+") {
                continue;
            }
            assert!(
                staged.contains(line),
                "the stager dropped or rewrote `{line}`"
            );
        }
    }

    #[test]
    fn the_staged_file_says_where_it_came_from() {
        assert!(staged().starts_with("# Generated by `cargo xtask package arch`"));
    }

    /// The rewrite is text, so it has to notice when the text it expects is no
    /// longer there rather than staging a file that builds the wrong thing.
    #[test]
    fn staging_refuses_a_pkgbuild_it_does_not_recognize() {
        for unrecognized in [
            "pkgname=cabalmail\nsource=(\"$pkgname::git+$url.git#tag=$pkgver\")\n",
            "pkgname=cabalmail\npkgver=1.5.0\nsource=(\"cabalmail.tar.gz\")\n",
            "pkgver=1.5.0\npkgver=1.5.1\nsource=(\"git+$url\")\n",
        ] {
            assert!(
                stage_pkgbuild(unrecognized, "1.5.0.r0.gabc", Path::new("/repo"), "abc").is_err(),
                "the stager accepted a PKGBUILD it cannot rewrite:\n{unrecognized}"
            );
        }
    }

    #[test]
    fn a_tree_version_reads_as_later_than_its_tag() {
        assert_eq!(
            pkgver_from_describe("1.5.0-3-gabc1234").unwrap(),
            "1.5.0.r3.gabc1234"
        );
        assert_eq!(
            pkgver_from_describe("1.5.0-0-gabc1234\n").unwrap(),
            "1.5.0.r0.gabc1234"
        );
    }

    /// makepkg splits a package file name on hyphens, so a pkgver carrying one
    /// produces a package that cannot be read back.
    #[test]
    fn a_tree_version_has_no_hyphen_in_it() {
        assert!(
            !pkgver_from_describe("1.5.0-12-gdeadbee")
                .unwrap()
                .contains('-')
        );
    }

    #[test]
    fn a_description_that_is_not_a_release_tag_is_an_error() {
        for not_a_release in ["1.5.0", "", "v1.5.0-3-abc1234", "-3-gabc"] {
            assert!(
                pkgver_from_describe(not_a_release).is_err(),
                "`{not_a_release}` was accepted as a release description"
            );
        }
    }

    /// The file names this matches against are makepkg's, so the name here
    /// has to be the one the PKGBUILD declares.
    #[test]
    fn the_package_name_is_the_one_the_pkgbuild_declares() {
        let pkgbuild = std::fs::read_to_string(
            Path::new(env!("CARGO_MANIFEST_DIR"))
                .parent()
                .expect("xtask lives inside the workspace root")
                .join("packaging/arch/PKGBUILD"),
        )
        .expect("the PKGBUILD reads");
        let declared = pkgbuild
            .lines()
            .find_map(|line| line.strip_prefix("pkgname="))
            .expect("the PKGBUILD declares pkgname");
        assert_eq!(declared.trim_matches('\''), PKGNAME);
    }

    /// A build environment with `debug` in its OPTIONS writes a second
    /// package. It is an artifact of this build, not a leftover from an
    /// earlier one, and treating it as ambiguity failed a green build in CI.
    #[test]
    fn the_debug_package_is_not_mistaken_for_a_stale_one() {
        let names = vec![
            "cabalmail-1.5.0.r3.gabc1234-1-x86_64.pkg.tar.zst".to_owned(),
            "cabalmail-debug-1.5.0.r3.gabc1234-1-x86_64.pkg.tar.zst".to_owned(),
        ];
        assert_eq!(
            choose_package(&names, "cabalmail", "1.5.0.r3.gabc1234").unwrap(),
            "cabalmail-1.5.0.r3.gabc1234-1-x86_64.pkg.tar.zst"
        );
    }

    /// A package from an earlier version is a leftover, and picking it would
    /// lint something nobody just built.
    #[test]
    fn a_package_from_another_version_is_not_this_build() {
        let names = vec!["cabalmail-1.4.0.r1.gdeadbee-1-x86_64.pkg.tar.zst".to_owned()];
        let error = choose_package(&names, "cabalmail", "1.5.0.r3.gabc1234")
            .expect_err("that is not this build");
        assert!(error.contains("1.4.0.r1.gdeadbee"), "{error}");
    }

    #[test]
    fn two_packages_of_the_same_version_are_ambiguous() {
        let names = vec![
            "cabalmail-1.5.0-1-x86_64.pkg.tar.zst".to_owned(),
            "cabalmail-1.5.0-1-aarch64.pkg.tar.zst".to_owned(),
        ];
        assert!(choose_package(&names, "cabalmail", "1.5.0").is_err());
    }

    #[test]
    fn no_package_at_all_says_what_was_there_instead() {
        let error = choose_package(&[], "cabalmail", "1.5.0").expect_err("nothing was built");
        assert!(error.contains("nothing"), "{error}");
    }

    #[test]
    fn namcap_warnings_are_advice_and_errors_are_not() {
        let report = "cabalmail W: Dependency included and not needed ('glib2')\n\
                      cabalmail E: Dependency detected and not included (gtk4)\n\
                      cabalmail I: Some info\n";
        let errors = namcap_errors(report);
        assert_eq!(errors.len(), 1);
        assert!(errors[0].contains("Dependency detected"));
        assert!(namcap_errors("cabalmail W: only a warning\n").is_empty());
    }

    #[test]
    fn every_distro_is_either_built_or_names_the_work_item_that_will_build_it() {
        assert_eq!(pending_work_item("arch").unwrap(), None);
        assert!(
            pending_work_item("deb")
                .unwrap()
                .unwrap()
                .contains("Phase 8")
        );
        assert!(
            pending_work_item("rpm")
                .unwrap()
                .unwrap()
                .contains("Phase 8")
        );
    }

    #[test]
    fn an_unknown_distro_lists_the_known_ones() {
        let error = pending_work_item("slackware").expect_err("no such distribution");
        for name in distro_names() {
            assert!(
                error.contains(name),
                "the error should list `{name}`: {error}"
            );
        }
    }
}

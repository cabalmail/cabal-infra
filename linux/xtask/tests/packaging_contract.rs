//! The Arch package and everything it has to agree with.
//!
//! `packaging/arch/PKGBUILD` is a bash script that no test can build here — the
//! machine running these tests is not necessarily Arch, and `makepkg` needs a
//! container and several minutes. What can be checked cheaply is that it still
//! agrees with the things it is meant to agree with: the dependency list every
//! other packaging target reads, the JavaScript pins that live in React's
//! lockfile, the four vendored files `sync-vendored.sh` writes, and the data
//! files it installs. Each of those is a break that would otherwise surface as
//! a red packaging job minutes into a push, or - worse - as a package that
//! builds and is missing something.

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};

fn linux_dir() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("xtask lives inside the workspace root")
        .to_path_buf()
}

fn repo_root() -> PathBuf {
    linux_dir()
        .parent()
        .expect("the workspace lives inside the repository")
        .to_path_buf()
}

fn read(path: &Path) -> String {
    std::fs::read_to_string(path).unwrap_or_else(|e| panic!("reading {}: {e}", path.display()))
}

fn pkgbuild() -> String {
    read(&linux_dir().join("packaging/arch/PKGBUILD"))
}

/// A `name=('a' 'b')` array, flattened. Only the single-line form the PKGBUILD
/// uses is understood; a wrapped array fails here rather than being read as a
/// shorter list.
fn array(pkgbuild: &str, name: &str) -> BTreeSet<String> {
    let prefix = format!("{name}=(");
    let line = pkgbuild
        .lines()
        .find(|line| line.starts_with(&prefix))
        .unwrap_or_else(|| panic!("the PKGBUILD declares no `{name}`"));
    let inside = line
        .strip_prefix(&prefix)
        .and_then(|rest| rest.strip_suffix(')'))
        .unwrap_or_else(|| panic!("`{name}` is not one line of the form {name}=(...)"));
    inside
        .split_whitespace()
        .map(|entry| entry.trim_matches('\'').to_owned())
        .collect()
}

/// The bracketed sections of `packaging/deps/arch.txt`: `# [depends]` and the
/// package names under it, up to the next heading.
fn deps_sections() -> Vec<(String, BTreeSet<String>)> {
    let text = read(&linux_dir().join("packaging/deps/arch.txt"));
    let mut sections: Vec<(String, BTreeSet<String>)> = Vec::new();
    for line in text.lines() {
        let line = line.trim();
        if let Some(heading) = line
            .strip_prefix("# [")
            .and_then(|rest| rest.strip_suffix(']'))
        {
            sections.push((heading.to_owned(), BTreeSet::new()));
            continue;
        }
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let (_, packages) = sections
            .last_mut()
            .expect("a package name appears before any section heading");
        packages.insert(line.to_owned());
    }
    assert!(!sections.is_empty(), "arch.txt declares no sections");
    sections
}

fn section(name: &str) -> BTreeSet<String> {
    deps_sections()
        .into_iter()
        .find(|(heading, _)| heading == name)
        .unwrap_or_else(|| panic!("arch.txt has no `[{name}]` section"))
        .1
}

/// The version `npm ci` would install, out of React's lockfile — the pin the
/// PKGBUILD has to carry, and the one Dependabot bumps.
fn locked_version(package: &str) -> String {
    let lock = read(&repo_root().join("react/admin/package-lock.json"));
    let key = format!("\"node_modules/{package}\"");
    let at = lock
        .find(&key)
        .unwrap_or_else(|| panic!("react/admin/package-lock.json has no entry for {package}"));
    let field = "\"version\": \"";
    let start = lock[at..]
        .find(field)
        .map(|offset| at + offset + field.len())
        .unwrap_or_else(|| panic!("{package}'s lockfile entry has no version"));
    let end = lock[start..]
        .find('"')
        .map(|offset| start + offset)
        .expect("the version is a quoted string");
    lock[start..end].to_owned()
}

/// A `_name=value` assignment from the PKGBUILD.
fn pkgbuild_variable(pkgbuild: &str, name: &str) -> String {
    let prefix = format!("{name}=");
    pkgbuild
        .lines()
        .find_map(|line| line.strip_prefix(&prefix))
        .unwrap_or_else(|| panic!("the PKGBUILD declares no `{name}`"))
        .trim_matches('\'')
        .to_owned()
}

/// One list of system packages, the way `packaging/deps/ubuntu.txt` is one
/// list for the Debian family. A dependency added to the PKGBUILD alone would
/// be missing from the CI container that has to install it before makepkg can
/// check for it.
#[test]
fn the_pkgbuild_declares_the_dependencies_the_list_declares() {
    let pkgbuild = pkgbuild();
    for name in ["depends", "makedepends"] {
        assert_eq!(
            array(&pkgbuild, name),
            section(name),
            "`{name}` in packaging/arch/PKGBUILD and the `[{name}]` section of \
             packaging/deps/arch.txt disagree"
        );
    }
}

/// `[tools]` is what `cargo xtask package arch` runs around makepkg, not what
/// makepkg builds with. A tool that drifted into the PKGBUILD's arrays would
/// become a dependency of every AUR build for no reason.
#[test]
fn the_tools_are_not_build_dependencies() {
    let pkgbuild = pkgbuild();
    let declared: BTreeSet<String> = array(&pkgbuild, "depends")
        .union(&array(&pkgbuild, "makedepends"))
        .cloned()
        .collect();
    for tool in section("tools") {
        assert!(
            !declared.contains(&tool),
            "`{tool}` is a [tools] entry but the PKGBUILD declares it as a \
             dependency"
        );
    }
}

/// The property that keeps the Linux composer inside Dependabot's reach: the
/// versions come from React's manifest, wherever they are consumed. A bump
/// there has to reach the PKGBUILD, and this is what says so.
#[test]
fn the_pinned_javascript_matches_the_react_lockfile() {
    let pkgbuild = pkgbuild();
    for (package, variable) in [
        ("marked", "_marked_version"),
        ("turndown", "_turndown_version"),
    ] {
        let pinned = pkgbuild_variable(&pkgbuild, variable);
        assert_eq!(
            pinned,
            locked_version(package),
            "the PKGBUILD pins {package} {pinned}, which is not what \
             react/admin/package-lock.json installs"
        );
        assert!(
            pkgbuild.contains(&format!(
                "https://registry.npmjs.org/{package}/-/{package}-${variable}.tgz"
            )),
            "the {package} source is no longer fetched from the registry at the \
             pinned version"
        );
        assert!(
            pkgbuild.contains(&format!("noextract=(\"{package}-${variable}.tgz\""))
                || pkgbuild.contains(&format!("           \"{package}-${variable}.tgz\"")),
            "both npm tarballs unpack to package/, so {package} has to be in \
             noextract for prepare() to place it itself"
        );
    }
}

/// makepkg and `sync-vendored.sh` produce the same four files under the same
/// names. They are two implementations of one job - a developer checkout uses
/// node_modules, a package build uses the upstream tarballs - and a composer
/// that finds a file under a different name in one of them is a bug nobody
/// sees until Phase 5.
#[test]
fn the_package_vendors_the_same_files_the_script_does() {
    let pkgbuild = pkgbuild();
    let script = read(&linux_dir().join("scripts/sync-vendored.sh"));

    let mut written: Vec<String> = script
        .match_indices("$DEST_DIR/")
        .map(|(at, marker)| {
            let rest = &script[at + marker.len()..];
            let end = rest.find('"').expect("a destination path is quoted");
            rest[..end].to_owned()
        })
        .collect();
    written.sort();
    written.dedup();
    assert!(!written.is_empty(), "the script vendors nothing");

    for file in written {
        assert!(
            pkgbuild.contains(&format!("$editor/{file}")),
            "sync-vendored.sh writes `{file}` but the PKGBUILD does not"
        );
    }
}

/// Every file the package installs out of the tree, and the one directory it
/// must not write to. A renamed data file would otherwise fail inside a
/// container, on a push that looked unrelated.
#[test]
fn everything_the_package_installs_exists() {
    let pkgbuild = pkgbuild();
    let installed = [
        "cabalmail-gtk/data/cabalmail.5.md",
        "cabalmail-gtk/data/config.example.toml",
        "cabalmail-gtk/data/com.cabalmail.Cabalmail.desktop.in",
        "cabalmail-gtk/data/com.cabalmail.Cabalmail.metainfo.xml.in",
        "cabalmail-gtk/data/icons/hicolor/scalable/apps/com.cabalmail.Cabalmail.svg",
    ];
    for file in installed {
        assert!(
            pkgbuild.contains(file),
            "the PKGBUILD no longer installs {file}"
        );
        assert!(
            linux_dir().join(file).is_file(),
            "the PKGBUILD installs {file}, which does not exist"
        );
    }
    assert!(
        repo_root().join("LICENSE.md").is_file(),
        "the PKGBUILD installs LICENSE.md, which does not exist"
    );
}

/// `/etc/xdg/cabalmail/` belongs to the administrator. A file shipped there
/// would make "no system configuration present" indistinguishable from "the
/// administrator chose these defaults", which the configuration model relies
/// on being distinguishable.
#[test]
fn the_package_installs_nothing_into_the_system_config_directory() {
    for line in pkgbuild().lines() {
        let statement = line.trim();
        if !statement.starts_with("install ") {
            continue;
        }
        assert!(
            !statement.contains("/etc/"),
            "the package writes into /etc: {statement}"
        );
    }
}

/// The man page is rendered from Markdown by go-md2man, whose title block is
/// roff written straight into `.TH`. Anything else there produces a man page
/// with a broken header, which no test downstream of the conversion would
/// notice.
#[test]
fn the_man_page_carries_a_roff_title_block() {
    let man = read(&linux_dir().join("cabalmail-gtk/data/cabalmail.5.md"));
    let first = man.lines().next().expect("the man page is not empty");
    assert_eq!(
        first, "% \"CABALMAIL\" \"5\" \"\" \"Cabalmail\" \"File Formats Manual\"",
        "the title block is what go-md2man turns into `.TH`; it has to stay \
         quoted roff fields"
    );
}

/// The packaging job, asserted the way the workflow contract asserts the
/// others: a job that stopped running the packaging build would take the only
/// proof that the PKGBUILD still works with it.
#[test]
fn a_job_builds_the_package_on_every_push() {
    let workflow = read(&repo_root().join(".github/workflows/linux.yml"));
    assert!(
        workflow.contains("cargo xtask package arch"),
        "no job in linux.yml builds the Arch package"
    );
    assert!(
        workflow.contains("install-linux-deps.sh arch"),
        "the packaging job does not install the dependencies from \
         packaging/deps/arch.txt"
    );
    assert!(
        workflow.contains("fetch-depth: 0"),
        "makepkg clones the checkout and derives pkgver from its tags, so the \
         packaging job needs the full history"
    );
}

//! Guards on the workspace's own shape.
//!
//! These are the properties that are cheap to state and expensive to
//! rediscover: the toolchain pin is exact, its components are the ones CI
//! needs, the workspace edition matches the pin, and every declared member
//! actually exists. They fail here rather than in a packaging container.

use std::path::{Path, PathBuf};

fn linux_dir() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("xtask lives inside the workspace root")
        .to_path_buf()
}

fn read(relative: &str) -> String {
    let path = linux_dir().join(relative);
    std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("reading {}: {e}", path.display()))
}

fn parse(relative: &str) -> toml::Table {
    read(relative)
        .parse::<toml::Table>()
        .unwrap_or_else(|e| panic!("parsing {relative}: {e}"))
}

/// `channel = "1.97.1"`, never `"stable"` or `"1.97"`. With `clippy -D warnings`
/// in CI, a floating channel means a Rust release can redden CI on lints nobody
/// wrote code against.
#[test]
fn toolchain_channel_is_an_exact_version() {
    let toolchain = parse("rust-toolchain.toml");
    let channel = toolchain["toolchain"]["channel"]
        .as_str()
        .expect("channel is a string");

    let components: Vec<&str> = channel.split('.').collect();
    assert_eq!(
        components.len(),
        3,
        "toolchain channel `{channel}` is not an exact x.y.z version"
    );
    for component in components {
        assert!(
            !component.is_empty() && component.bytes().all(|b| b.is_ascii_digit()),
            "toolchain channel `{channel}` is not an exact x.y.z version"
        );
    }
}

/// CI runs clippy and rustfmt from the pinned toolchain, and coverage needs
/// llvm-tools. A dropped component surfaces as a confusing CI failure.
#[test]
fn toolchain_carries_the_components_ci_needs() {
    let toolchain = parse("rust-toolchain.toml");
    let components: Vec<&str> = toolchain["toolchain"]["components"]
        .as_array()
        .expect("components is an array")
        .iter()
        .map(|value| value.as_str().expect("component is a string"))
        .collect();

    for required in ["clippy", "rustfmt", "llvm-tools"] {
        assert!(
            components.contains(&required),
            "rust-toolchain.toml is missing the `{required}` component"
        );
    }
}

/// `rust-version` states what the workspace is built with. If it drifts above
/// the pin, the pinned toolchain cannot build the workspace at all.
#[test]
fn rust_version_matches_the_pinned_toolchain() {
    let channel = parse("rust-toolchain.toml")["toolchain"]["channel"]
        .as_str()
        .expect("channel is a string")
        .to_owned();
    let package = parse("Cargo.toml");
    let rust_version = package["workspace"]["package"]["rust-version"]
        .as_str()
        .expect("rust-version is a string");

    let minor = |version: &str| -> (u32, u32) {
        let mut parts = version.split('.');
        let major = parts.next().unwrap().parse().expect("major is numeric");
        let minor = parts.next().unwrap().parse().expect("minor is numeric");
        (major, minor)
    };

    assert!(
        minor(rust_version) <= minor(&channel),
        "rust-version {rust_version} is newer than the pinned toolchain {channel}"
    );
}

#[test]
fn workspace_is_edition_2024() {
    let package = parse("Cargo.toml");
    assert_eq!(
        package["workspace"]["package"]["edition"].as_str(),
        Some("2024")
    );
}

#[test]
fn every_declared_member_exists() {
    let workspace = parse("Cargo.toml");
    let members = workspace["workspace"]["members"]
        .as_array()
        .expect("members is an array");

    assert!(!members.is_empty(), "workspace declares no members");
    for member in members {
        let member = member.as_str().expect("member is a string");
        let manifest = linux_dir().join(member).join("Cargo.toml");
        assert!(
            manifest.is_file(),
            "workspace member `{member}` has no {}",
            manifest.display()
        );
    }
}

/// The kit's freedom from GUI dependencies is what lets its tests run on a bare
/// runner. Phase 2 adds the transitive `cargo tree` check in CI; this catches
/// the direct case at the point someone types it.
#[test]
fn kit_declares_no_gui_dependency() {
    let manifest = read("cabalmail-kit/Cargo.toml");
    let declared = manifest
        .parse::<toml::Table>()
        .expect("kit manifest parses");
    let sections = ["dependencies", "dev-dependencies", "build-dependencies"];

    for section in sections {
        let Some(table) = declared.get(section).and_then(toml::Value::as_table) else {
            continue;
        };
        for name in table.keys() {
            let lowered = name.to_lowercase();
            assert!(
                !(lowered.contains("gtk") || lowered.contains("webkit") || lowered.contains("adw")),
                "cabalmail-kit must have no GUI dependency, found `{name}` in [{section}]"
            );
        }
    }
}

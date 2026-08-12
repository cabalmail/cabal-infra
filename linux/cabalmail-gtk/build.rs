//! Compiles the Blueprint UI definitions to GtkBuilder XML, then bundles them
//! (with everything else under `resources/`) into a GResource the binary
//! carries.
//!
//! There is deliberately **no fallback** for a missing `blueprint-compiler`:
//! falling back to hand-written `.ui` files would mean two UI formats in the
//! tree and a build that succeeds differently depending on what happens to be
//! installed. A missing compiler is a hard failure naming the package.

use std::path::{Path, PathBuf};
use std::process::Command;
use std::{env, fs, io};

/// Where the `.blp` sources and the `.gresource.xml` manifest live.
const RESOURCE_DIR: &str = "resources";

/// The GResource manifest, relative to the crate root.
const MANIFEST: &str = "resources/cabalmail.gresource.xml";

/// The bundle's file name inside `OUT_DIR`; `gio::resources_register_include!`
/// in `src/lib.rs` names the same file.
const BUNDLE: &str = "cabalmail.gresource";

fn main() {
    println!("cargo::rerun-if-changed={RESOURCE_DIR}");

    let out_dir = PathBuf::from(env::var_os("OUT_DIR").expect("cargo sets OUT_DIR"));
    // Compiled `.ui` files land under `OUT_DIR/ui/`, which is why the manifest
    // refers to them as `ui/<name>.ui` and why `OUT_DIR` is a source directory
    // for `glib-compile-resources`.
    let ui_dir = out_dir.join("ui");
    fs::create_dir_all(&ui_dir)
        .unwrap_or_else(|error| panic!("creating {}: {error}", ui_dir.display()));

    let blueprints = blueprints();
    assert!(
        !blueprints.is_empty(),
        "no .blp sources in {RESOURCE_DIR}/ — the window template is not optional"
    );
    for blueprint in &blueprints {
        println!("cargo::rerun-if-changed={}", blueprint.display());
    }
    compile_blueprints(&blueprints, &ui_dir);

    glib_build_tools::compile_resources(&[Path::new(RESOURCE_DIR), &out_dir], MANIFEST, BUNDLE);
}

/// Every `.blp` file in `resources/`, sorted so the compiler is invoked with a
/// stable argument list.
fn blueprints() -> Vec<PathBuf> {
    let mut found: Vec<PathBuf> = fs::read_dir(RESOURCE_DIR)
        .unwrap_or_else(|error| panic!("reading {RESOURCE_DIR}/: {error}"))
        .map(|entry| entry.expect("the directory entry reads").path())
        .filter(|path| path.extension().is_some_and(|extension| extension == "blp"))
        .collect();
    found.sort();
    found
}

fn compile_blueprints(blueprints: &[PathBuf], ui_dir: &Path) {
    let output = Command::new("blueprint-compiler")
        .arg("batch-compile")
        .arg(ui_dir)
        .arg(RESOURCE_DIR)
        .args(blueprints)
        .output();

    let output = match output {
        Ok(output) => output,
        Err(error) if error.kind() == io::ErrorKind::NotFound => panic!("{}", MISSING_COMPILER),
        Err(error) => panic!("running blueprint-compiler: {error}"),
    };

    assert!(
        output.status.success(),
        "blueprint-compiler failed:\n{}{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr),
    );
}

const MISSING_COMPILER: &str = "\
blueprint-compiler was not found on PATH.

The interface is written in Blueprint and compiled to GtkBuilder XML at build
time. Install it:

  Arch            pacman -S blueprint-compiler
  Debian/Ubuntu   apt install blueprint-compiler
  Fedora/RHEL     dnf install blueprint-compiler
";

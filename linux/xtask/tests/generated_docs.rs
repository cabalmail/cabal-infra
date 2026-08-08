//! Guards on the documentation generated from the configuration schema.
//!
//! `config.example.toml` and the KEYS section of `cabalmail.5.md` are produced
//! from the same table the parser reads, so a key cannot exist in the client
//! and be missing from the manual. These tests are what makes that true of the
//! *committed* files rather than only of the generator: they regenerate and
//! compare.
//!
//! To update the committed files after a schema change:
//!
//! ```sh
//! CABALMAIL_UPDATE_DOCS=1 cargo test -p xtask
//! ```

use std::path::{Path, PathBuf};

use cabalmail_kit::config::{Key, docs};

/// Markers delimiting the generated block inside the hand-written man page.
const BEGIN: &str = "<!-- BEGIN GENERATED KEYS -->";
const END: &str = "<!-- END GENERATED KEYS -->";

fn linux_dir() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("xtask lives inside the workspace root")
        .to_path_buf()
}

fn data_file(name: &str) -> PathBuf {
    linux_dir().join("cabalmail-gtk").join("data").join(name)
}

/// Whether the caller asked for the committed files to be rewritten.
fn updating() -> bool {
    std::env::var_os("CABALMAIL_UPDATE_DOCS").is_some()
}

/// Compares `expected` against the file, rewriting it instead when
/// `CABALMAIL_UPDATE_DOCS` is set.
fn assert_matches(path: &Path, expected: &str) {
    let actual = std::fs::read_to_string(path).unwrap_or_default();
    if actual == expected {
        return;
    }
    if updating() {
        std::fs::create_dir_all(path.parent().expect("the file has a parent"))
            .expect("the data directory is created");
        std::fs::write(path, expected)
            .unwrap_or_else(|e| panic!("writing {}: {e}", path.display()));
        return;
    }
    panic!(
        "{} is stale — the configuration schema has changed.\n\
         Regenerate it with `CABALMAIL_UPDATE_DOCS=1 cargo test -p xtask`.",
        path.display()
    );
}

#[test]
fn the_example_config_matches_the_schema() {
    assert_matches(&data_file("config.example.toml"), &docs::example_toml());
}

#[test]
fn the_man_page_key_list_matches_the_schema() {
    let path = data_file("cabalmail.5.md");
    let text = std::fs::read_to_string(&path)
        .unwrap_or_else(|e| panic!("reading {}: {e}", path.display()));

    let (head, rest) = text
        .split_once(BEGIN)
        .unwrap_or_else(|| panic!("{} has no {BEGIN} marker", path.display()));
    let (_, tail) = rest
        .split_once(END)
        .unwrap_or_else(|| panic!("{} has no {END} marker", path.display()));

    let expected = format!(
        "{head}{BEGIN}\n\n{}\n{END}{tail}",
        docs::man_keys_markdown()
    );
    assert_matches(&path, &expected);
}

/// The plan's requirement in its own words: no key may exist in the parser and
/// be missing from the man page. The generated-block comparison above implies
/// this, but stating it separately means the failure says what is actually
/// wrong when someone edits the committed page by hand.
#[test]
fn the_man_page_documents_every_key() {
    let text = std::fs::read_to_string(data_file("cabalmail.5.md")).expect("the man page reads");
    for key in Key::ALL.iter().copied() {
        assert!(
            text.contains(&format!("#### `{}`", key.name())),
            "`{key}` is not documented in cabalmail.5.md"
        );
    }
}

/// The example file ships as reference documentation to
/// `/usr/share/doc/cabalmail/`, and a user copying it must not be handed a
/// file the client then refuses to start on.
#[test]
fn the_committed_example_config_is_accepted_by_the_parser() {
    let path = data_file("config.example.toml");
    let text = std::fs::read_to_string(&path).expect("the example file reads");
    let found = cabalmail_kit::config::file::parse(&path, &text)
        .unwrap_or_else(|e| panic!("the committed example file does not parse: {e}"));
    assert!(
        found.is_empty(),
        "the example file asserts settings rather than documenting them: {found:?}"
    );
}

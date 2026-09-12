//! The reader's default link colour is the one the design tokens declare.
//!
//! `cabalmail-kit`'s `policy::html_rewrite` injects a default `a { color: … }`
//! into every received message, and that colour is the brand accent. The Apple
//! client takes the same value from a generated token table precisely so it
//! cannot drift from the design source; nothing generates Rust, so the constant
//! is written by hand and held here instead.
//!
//! A comment saying "keep these in step" reaches only whoever edits the file it
//! sits in. This reaches whoever edits either.

use cabalmail_kit::policy::html_rewrite::BRAND_LINK_COLOR;

mod support;

/// The token the reader's link colour is, and the variant it takes.
///
/// `fg` is the accent as text and glyphs, which is what a link is. The light
/// variant, because the reader pins received mail to a light rendering — the
/// dark one has no call site yet and is deliberately not carried.
const TOKEN: &str = "\"accent.forest.fg\"";
const VARIANT: &str = "\"light\"";

#[test]
fn the_readers_link_colour_is_the_brand_accent_token() {
    let path = support::repo_input("design/color-tokens.json");
    let table = std::fs::read_to_string(&path)
        .unwrap_or_else(|e| panic!("reading {}: {e}", path.display()));

    let (_, below) = table
        .split_once(TOKEN)
        .unwrap_or_else(|| panic!("{} declares no {TOKEN} token", path.display()));

    // Bounded to this token's own block. An unbounded scan would fall through
    // to the next token's `light` when this one lost the key, and pass green
    // against a colour belonging to something else — which is the one failure
    // this file exists to catch.
    let block = below
        .split_once("\n    }")
        .unwrap_or_else(|| panic!("the {TOKEN} token's block does not close"))
        .0;
    let declared = block
        .lines()
        .find_map(|line| line.trim().split_once(&format!("{VARIANT}: ")))
        .map(|(_, value)| value.trim().trim_end_matches(',').trim_matches('"'))
        .unwrap_or_else(|| {
            panic!("the {TOKEN} token has no {VARIANT} variant, so nothing holds the reader to it")
        });

    assert_eq!(
        declared.to_ascii_uppercase(),
        BRAND_LINK_COLOR.to_ascii_uppercase(),
        "the reader renders links {BRAND_LINK_COLOR} and the design tokens say \
         {declared}. Every message we display would carry the wrong accent."
    );
}

//! Rewriting a received HTML body before it is handed to the reader's
//! `WebKitWebView`.
//!
//! Purely string-level, so no JavaScript context is needed to do it — which
//! matters here more than it did on Apple: the reader runs with
//! `enable_javascript(false)` and there is nothing else to run script in.
//!
//! This is **not** a sanitizer. Script in a received message is neutralized by
//! that setting on the web view, the way the React reader's script-less iframe
//! sandbox neutralizes it there. What this does is inject the defaults a mail
//! body needs to lay out correctly, and resolve `cid:` references to the
//! inline images that came with the message.
//!
//! The Apple analog is `HTMLRewrite`.

/// Sets the layout viewport. Without it WebKit lays the document out at its
/// 980px desktop viewport and scales the result down to the pane width, so any
/// message that ships no viewport of its own — including the HTML alternative
/// our own `/send` generates — is unreadable without zooming.
const VIEWPORT_META: &str =
    "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">";

/// Has WebKit fetch `http` subresources over `https`. A body whose images are
/// still addressed over `http` otherwise renders as broken boxes even with
/// remote content allowed. A host with no `https` at all still fails, as
/// before; when remote content is off, the request is blocked either way and
/// this only changes what is asked for once it is allowed.
const UPGRADE_INSECURE_REQUESTS: &str =
    "<meta http-equiv=\"Content-Security-Policy\" content=\"upgrade-insecure-requests\">";

/// The brand link colour, light variant, as the reader's default.
///
/// A message that ships no link CSS of its own would otherwise render the
/// browser's blue, which is the one piece of an untouched message that reads as
/// "web page" rather than "Cabalmail".
///
/// `design/color-tokens.json` is where this value is decided, for every client.
/// Nothing generates Rust from it, so `xtask/tests/color_token_contract.rs`
/// holds the two together instead — edit either and that test fails.
pub const BRAND_LINK_COLOR: &str = "#2E5235";

/// The default link style. The selector is deliberately bare `a` and carries no
/// `!important`, so any author declaration — a later `a { color: … }`, a
/// higher-specificity selector, or an inline `style=` — still wins, and author
/// fidelity is preserved.
fn default_link_style() -> String {
    format!("<style>a {{ color: {BRAND_LINK_COLOR}; }}</style>")
}

/// Everything injected on every render path, in order.
fn head_defaults() -> String {
    format!(
        "{VIEWPORT_META}{UPGRADE_INSECURE_REQUESTS}{}",
        default_link_style()
    )
}

/// One inline image the message carried: its Content-ID, and the `data:` URI
/// the reader should load instead.
pub type InlineImage<'a> = (&'a str, &'a str);

/// Rewrites `body` for display.
///
/// `cid:` references are resolved case-insensitively against `inline_images`;
/// anything not in the map is left alone, so a message referring to a part that
/// never arrived renders a broken image rather than a mangled document.
#[must_use]
pub fn rewrite<'a, I>(body: &str, inline_images: I) -> String
where
    I: IntoIterator<Item = InlineImage<'a>>,
{
    let images: Vec<(String, &str)> = inline_images
        .into_iter()
        .map(|(content_id, data_uri)| (content_id.to_ascii_lowercase(), data_uri))
        .collect();
    insert_head_defaults(&resolve_references(body, &images))
}

/// Replaces every `cid:` reference with the `data:` URI of the part it names.
///
/// Scanning once and matching the *whole* reference is what keeps two
/// Content-IDs where one is a prefix of the other — `logo` and `logo2` — from
/// corrupting each other. Replacing them one at a time, as the Apple original
/// does, resolves `cid:logo2` to the logo's URI followed by a stray `2`
/// whenever `logo` happens to be substituted first.
///
/// A reference runs to the first character that cannot be part of a
/// Content-ID: the quote or angle bracket that closes the attribute. Anything
/// with no matching part is left alone, so a message referring to a part that
/// never arrived renders a broken image rather than a mangled document.
fn resolve_references(body: &str, images: &[(String, &str)]) -> String {
    let lowered = body.to_ascii_lowercase();
    let mut result = String::with_capacity(body.len());
    let mut cursor = 0;

    while let Some(offset) = lowered[cursor..].find("cid:") {
        let start = cursor + offset;
        let reference = start + "cid:".len();
        let end = reference
            + body[reference..]
                .find(|character: char| {
                    !character.is_ascii_alphanumeric() && !"-_.@%+".contains(character)
                })
                .unwrap_or(body.len() - reference);

        result.push_str(&body[cursor..start]);
        let name = lowered[reference..end].to_owned();
        match images.iter().find(|(content_id, _)| *content_id == name) {
            Some((_, data_uri)) => result.push_str(data_uri),
            None => result.push_str(&body[start..end]),
        }
        cursor = end;
    }

    result.push_str(&body[cursor..]);
    result
}

/// Places the head defaults at the *start* of the document head, so a sender
/// that declares its own viewport still wins — WebKit takes the last
/// declaration in document order.
///
/// The insertion point is the whole difficulty. Prepending ahead of a
/// `<!DOCTYPE>` pushes the author's page into quirks mode and changes how their
/// CSS renders, which is exactly what displaying a message unaltered must not
/// do. So: `<head>` first, then `<html>`, then the doctype. A bare fragment —
/// the shape our own `/send` produces — has none of them and is simply
/// prefixed, since the parser synthesizes a head around it.
fn insert_head_defaults(html: &str) -> String {
    let defaults = head_defaults();
    // ASCII folding, because the offsets found in this copy index the
    // original. `to_lowercase` is Unicode-aware and changes the length of
    // what it folds, which puts every offset after such a character wrong.
    // Tag names are ASCII, so nothing is lost.
    let lowered = html.to_ascii_lowercase();
    for tag in ["<head", "<html", "<!doctype"] {
        let Some(open) = opening_tag(&lowered, tag) else {
            continue;
        };
        let Some(offset) = lowered[open..].find('>') else {
            continue;
        };
        let after = open + offset + 1;
        return format!("{}{defaults}{}", &html[..after], &html[after..]);
    }
    format!("{defaults}{html}")
}

/// Where `tag` opens in `lowered`, as a tag rather than as a prefix of a
/// longer name.
///
/// `<head` is a prefix of `<header>`, and a fragment that opens with one would
/// otherwise take the defaults into the middle of its own markup. A real tag
/// ends at whitespace, `>`, or `/`; anything else continues the name.
fn opening_tag(lowered: &str, tag: &str) -> Option<usize> {
    let mut from = 0;
    while let Some(offset) = lowered[from..].find(tag) {
        let start = from + offset;
        let after = start + tag.len();
        let ends_here = lowered[after..]
            .chars()
            .next()
            .is_none_or(|character| character.is_whitespace() || "/>".contains(character));
        if ends_here {
            return Some(start);
        }
        from = after;
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rewritten(html: &str) -> String {
        rewrite(html, [])
    }

    #[test]
    fn every_body_gets_a_viewport_and_an_upgrade_directive() {
        for html in [
            "<p>x</p>",
            "<html><head></head><body>x</body></html>",
            "<!DOCTYPE html><body>x</body>",
        ] {
            let result = rewritten(html);
            assert!(result.contains(VIEWPORT_META), "{result}");
            assert!(result.contains(UPGRADE_INSECURE_REQUESTS), "{result}");
        }
    }

    #[test]
    fn the_defaults_land_inside_an_existing_head() {
        assert_eq!(
            rewritten("<html><head><title>hi</title></head><body>hi</body></html>"),
            format!(
                "<html><head>{}<title>hi</title></head><body>hi</body></html>",
                head_defaults()
            )
        );
    }

    /// The one thing displaying a message unaltered must not change: a doctype
    /// that is no longer first puts the author's page into quirks mode.
    #[test]
    fn a_doctype_stays_first_when_there_is_no_head() {
        let result = rewritten("<!DOCTYPE html>\n<body>hi</body>");
        assert!(
            result.starts_with(&format!("<!DOCTYPE html>{}", head_defaults())),
            "{result}"
        );
    }

    #[test]
    fn the_defaults_go_after_the_html_tag_when_there_is_no_head() {
        assert_eq!(
            rewritten("<html><body>hi</body></html>"),
            format!("<html>{}<body>hi</body></html>", head_defaults())
        );
    }

    /// The shape our own `/send` Lambda's HTML alternative arrives in.
    #[test]
    fn a_bare_fragment_is_prefixed() {
        assert_eq!(
            rewritten("<p>two words</p>"),
            format!("{}<p>two words</p>", head_defaults())
        );
    }

    /// Ours is a default, not an override: a sender's own viewport has to come
    /// later in document order for WebKit to honour theirs.
    #[test]
    fn a_senders_own_viewport_survives_and_wins() {
        let sender = "<meta name=\"viewport\" content=\"width=600\">";
        let result = rewritten(&format!(
            "<html><head>{sender}</head><body>hi</body></html>"
        ));
        let ours = result.find(VIEWPORT_META).expect("ours is injected");
        let theirs = result.find(sender).expect("theirs survives");
        assert!(ours < theirs, "{result}");
    }

    /// Tags are matched case-insensitively, and the document keeps the case it
    /// was written in.
    #[test]
    fn an_uppercase_head_is_found_and_left_as_it_was() {
        let result = rewritten("<HTML><HEAD></HEAD><BODY>hi</BODY></HTML>");
        assert!(result.starts_with("<HTML><HEAD>"), "{result}");
        assert!(result.contains(VIEWPORT_META), "{result}");
    }

    #[test]
    fn inline_image_references_are_resolved_whatever_their_case() {
        let uri = "data:image/png;base64,AAA";
        let result = rewrite(
            "<img src=\"cid:LogoPart\"><img src=\"CID:LogoPart\">",
            [("LogoPart", uri)],
        );
        assert!(!result.to_lowercase().contains("cid:"), "{result}");
        assert_eq!(result.matches(uri).count(), 2, "{result}");
    }

    /// A part that never arrived leaves a broken image, which is honest. What
    /// it must not do is take the rest of the document with it.
    #[test]
    fn a_reference_with_no_part_is_left_alone() {
        let result = rewrite("<img src=\"cid:missing\">", [("other", "data:,x")]);
        assert!(result.contains("cid:missing"), "{result}");
    }

    /// A malformed tag with no closing bracket must not produce a document
    /// with the defaults spliced into the middle of it.
    #[test]
    fn an_unclosed_tag_falls_through_to_prefixing() {
        let result = rewritten("<head");
        assert_eq!(result, format!("{}<head", head_defaults()));
    }

    /// One Content-ID being a prefix of another is ordinary — a message with
    /// `logo` and `logo2` parts. Substituting them one at a time resolves
    /// `cid:logo2` to the first URI plus a stray `2`, which is how the Apple
    /// original behaves and is not worth porting.
    #[test]
    fn a_content_id_that_is_a_prefix_of_another_is_not_corrupted_by_it() {
        let result = rewrite(
            "<img src=\"cid:logo\"><img src=\"cid:logo2\">",
            [("logo", "data:,one"), ("logo2", "data:,two")],
        );
        assert!(result.contains("src=\"data:,one\""), "{result}");
        assert!(result.contains("src=\"data:,two\""), "{result}");
        assert!(!result.contains("data:,one2"), "{result}");
    }

    /// The reverse order, since the defect depended on which part happened to
    /// be substituted first.
    #[test]
    fn the_order_the_parts_arrive_in_does_not_matter() {
        let result = rewrite(
            "<img src=\"cid:logo2\"><img src=\"cid:logo\">",
            [("logo2", "data:,two"), ("logo", "data:,one")],
        );
        assert_eq!(
            result,
            format!(
                "{}<img src=\"data:,two\"><img src=\"data:,one\">",
                head_defaults()
            )
        );
    }

    /// `<head` is a prefix of `<header>`. A fragment opening with one would
    /// otherwise have the defaults spliced into the middle of its own markup.
    #[test]
    fn a_header_element_is_not_mistaken_for_the_document_head() {
        assert_eq!(
            rewritten("<header>hi</header>"),
            format!("{}<header>hi</header>", head_defaults())
        );
    }

    /// The tags that *are* real still resolve, with or without attributes.
    #[test]
    fn a_tag_with_attributes_is_still_the_tag() {
        for (document, opening) in [
            (
                "<html lang=\"en\"><body>hi</body></html>",
                "<html lang=\"en\">",
            ),
            ("<head><title>t</title></head>", "<head>"),
        ] {
            let result = rewritten(document);
            assert!(
                result.starts_with(&format!("{opening}{}", head_defaults())),
                "{result}"
            );
        }
    }

    /// The empty body is what a message with no HTML alternative arrives as.
    #[test]
    fn an_empty_body_is_still_given_the_defaults() {
        assert_eq!(rewritten(""), head_defaults());
    }

    /// Case folding is done to find the tag, not to rewrite the document, so
    /// it must not move a single byte of it. Unicode lowercasing does: `İ`
    /// (U+0130) is two bytes and lowercases to three, `K` (U+212A) is three
    /// and lowercases to one. Either one before the tag shifts every offset
    /// after it, and a message is a string somebody else wrote.
    #[test]
    fn a_tag_is_found_at_its_real_offset_whatever_precedes_it() {
        for prefix in ["\u{130}\u{130}\u{130}", "\u{212a}\u{212a}\u{212a}", "über "] {
            let result = rewritten(&format!("{prefix}<html><body>hi</body></html>"));
            assert_eq!(
                result,
                format!("{prefix}<html>{}<body>hi</body></html>", head_defaults()),
                "the defaults landed in the wrong place after {prefix:?}"
            );
        }
    }

    /// The same shift, far enough along to run off the end of the document
    /// rather than land inside it.
    #[test]
    fn a_long_run_of_resizing_characters_does_not_panic() {
        let prefix = "\u{130}".repeat(10);
        let result = rewritten(&format!("{prefix}<head>"));
        assert_eq!(result, format!("{prefix}<head>{}", head_defaults()));
    }
}

//! The synced-preferences contract, asserted against the Lambda itself.
//!
//! `set_preferences` rejects an unknown key in the `app` map with a 400 *by
//! design*, so the set of keys the client may sync is closed by the server. A
//! client that drifts from it does not degrade — it 400s at runtime, on the
//! push, after the user has already changed the setting.
//!
//! These tests read `lambda/api/set_preferences/function.py` and compare it
//! with the client's key table, so a divergence in either direction fails CI
//! instead. Reading the Python as text keeps the check runnable in a
//! Rust-only container; the shapes involved are three literals, and a change
//! that broke this parse would be a change worth looking at anyway.

use std::collections::{BTreeMap, BTreeSet};

mod support;

use cabalmail_kit::config::{Key, Kind, Scope, Wire};

/// Keys the Lambda allows that this client deliberately does not carry.
///
/// `crash_reporting_enabled` drives MetricKit, which is Apple-only. The Linux
/// client never sends it, and `set_preferences` merges per key, so the iOS
/// setting survives a Linux push untouched. Anything else appearing here needs
/// a reason written next to it.
///
/// `dispose_advance` steers which message the Apple readers select after a
/// dispose; this client has no after-dispose auto-advance, so it neither
/// reads nor sends the key. `mark_read_advance` is its mark-as-read twin
/// (where the Apple readers go after the toolbar's mark-read) and is
/// unsupported for the same reason.
const DELIBERATELY_UNSUPPORTED: &[&str] = &[
    "crash_reporting_enabled",
    "dispose_advance",
    "mark_read_advance",
];

/// What the Lambda accepts, read out of its source.
struct LambdaContract {
    /// `APP_ALLOWED`: enum-valued keys and their permitted values.
    enums: BTreeMap<String, BTreeSet<String>>,
    /// The free-text keys `_validate_app` handles outside `APP_ALLOWED`.
    free_text: BTreeSet<String>,
    max_name_length: usize,
    max_signature_length: usize,
}

impl LambdaContract {
    fn read() -> Self {
        let path = support::repo_input("lambda/api/set_preferences/function.py");
        let source = std::fs::read_to_string(&path)
            .unwrap_or_else(|e| panic!("reading {}: {e}", path.display()));

        Self {
            enums: parse_app_allowed(&source),
            free_text: parse_free_text_keys(&source),
            max_name_length: parse_constant(&source, "MAX_NAME_LENGTH"),
            max_signature_length: parse_constant(&source, "MAX_SIGNATURE_LENGTH"),
        }
    }

    /// Every key the `app` map accepts.
    fn keys(&self) -> BTreeSet<String> {
        self.enums
            .keys()
            .cloned()
            .chain(self.free_text.clone())
            .collect()
    }
}

/// The `APP_ALLOWED = { 'key': {'a', 'b'}, ... }` literal.
fn parse_app_allowed(source: &str) -> BTreeMap<String, BTreeSet<String>> {
    let body = source
        .split_once("APP_ALLOWED = {")
        .expect("set_preferences declares APP_ALLOWED")
        .1
        .split_once("\n}")
        .expect("the APP_ALLOWED literal is closed at the start of a line")
        .0;

    let mut allowed = BTreeMap::new();
    for line in body.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let (key, values) = line
            .split_once(':')
            .unwrap_or_else(|| panic!("unparseable APP_ALLOWED entry: {line}"));
        let values = values
            .trim()
            .trim_start_matches('{')
            .trim_end_matches(',')
            .trim_end_matches('}');
        allowed.insert(
            unquote(key).to_owned(),
            values
                .split(',')
                .map(str::trim)
                .filter(|value| !value.is_empty())
                .map(|value| unquote(value).to_owned())
                .collect(),
        );
    }
    assert!(!allowed.is_empty(), "APP_ALLOWED parsed as empty");
    allowed
}

/// The `elif key == 'default_from_address':` arms of `_validate_app`.
fn parse_free_text_keys(source: &str) -> BTreeSet<String> {
    let body = source
        .split_once("def _validate_app(")
        .expect("set_preferences declares _validate_app")
        .1;
    body.lines()
        .take_while(|line| !line.starts_with("def _build_updates("))
        .filter_map(|line| line.trim().strip_prefix("elif key == "))
        .map(|rest| unquote(rest.trim_end_matches(':')).to_owned())
        .collect()
}

/// A `NAME = 123` module constant.
fn parse_constant(source: &str, name: &str) -> usize {
    source
        .lines()
        .find_map(|line| line.strip_prefix(&format!("{name} = ")))
        .unwrap_or_else(|| panic!("set_preferences declares no {name}"))
        .trim()
        .parse()
        .unwrap_or_else(|e| panic!("{name} is not a number: {e}"))
}

fn unquote(token: &str) -> &str {
    token.trim().trim_matches('\'').trim_matches('"')
}

/// The client's synced keys, by the name they are sent under.
fn client_app_keys() -> BTreeSet<String> {
    Key::ALL
        .iter()
        .copied()
        .filter(|key| key.scope() == Scope::Universal)
        .filter_map(|key| match key.spec().wire {
            Wire::App(name) => Some(name.to_owned()),
            _ => None,
        })
        .collect()
}

/// The heart of it: the two lists are the same list.
#[test]
fn the_client_and_the_lambda_agree_on_the_synced_key_set() {
    let lambda = LambdaContract::read();
    let mut expected = client_app_keys();
    for key in DELIBERATELY_UNSUPPORTED {
        assert!(
            lambda.keys().contains(*key),
            "`{key}` is listed as deliberately unsupported but the Lambda no longer allows it"
        );
        expected.insert((*key).to_owned());
    }

    assert_eq!(
        expected,
        lambda.keys(),
        "the client's synced keys and the Lambda's APP_ALLOWED have diverged — \
         a key only the client knows about would 400 on every push"
    );
}

/// Values, not just names. A renamed enum member is exactly as breaking as a
/// renamed key, and fails identically at runtime.
#[test]
fn every_shared_enum_has_the_same_values_on_both_sides() {
    let lambda = LambdaContract::read();
    for key in Key::ALL.iter().copied() {
        let Wire::App(name) = key.spec().wire else {
            continue;
        };
        if key.scope() != Scope::Universal {
            continue;
        }
        let Kind::Choice(allowed) = key.kind() else {
            continue;
        };
        let ours: BTreeSet<String> = allowed.iter().map(|value| (*value).to_owned()).collect();
        let theirs = lambda
            .enums
            .get(name)
            .unwrap_or_else(|| panic!("the Lambda has no enum for `{name}`"));
        assert_eq!(
            &ours, theirs,
            "`{key}` accepts different values than the Lambda"
        );
    }
}

/// The free-text limits are the Lambda's. Enforcing them client-side is what
/// turns a rejected push into an error naming the line the user wrote.
#[test]
fn the_free_text_limits_match_the_lambda_validators() {
    let lambda = LambdaContract::read();
    let cap = |key: Key| match key.kind() {
        Kind::Text { max_chars, .. } => max_chars,
        other => panic!("`{key}` is {other:?}, not text"),
    };

    assert_eq!(cap(Key::Name), lambda.max_name_length);
    assert_eq!(cap(Key::DefaultFromAddress), lambda.max_name_length);
    assert_eq!(cap(Key::Signature), lambda.max_signature_length);

    assert!(
        matches!(
            Key::Signature.kind(),
            Kind::Text {
                multiline: true,
                ..
            }
        ),
        "the signature validator permits newlines and tabs; the client must too"
    );
    assert!(
        matches!(
            Key::Name.kind(),
            Kind::Text {
                multiline: false,
                ..
            }
        ),
        "the display name lands in a header — control characters are an injection vector"
    );
}

/// The display name is a top-level member of the request body, not a member of
/// `app`, and is shared with the React client.
#[test]
fn the_display_name_rides_at_the_top_level_on_both_sides() {
    let lambda = LambdaContract::read();
    assert!(
        !lambda.keys().contains("name"),
        "`name` moved into the app map; the client sends it at the top level"
    );

    let source = std::fs::read_to_string(support::repo_input(
        "lambda/api/set_preferences/function.py",
    ))
    .expect("the Lambda source reads");
    assert!(
        source.contains("if 'name' in body:"),
        "the Lambda no longer validates a top-level `name`"
    );

    assert_eq!(Key::Name.spec().wire, Wire::TopLevel("name"));
}

/// Platform-scoped keys sync as `linux_`-prefixed scalars in the same map. The
/// `APP_ALLOWED` additions ship as their own PR against `lambda/api/` before
/// the Phase 6 work that pushes them, so they are *expected* to be absent here
/// for now. What must never happen is the reverse: a `linux_` key the server
/// allows that this client does not declare.
#[test]
fn every_linux_key_the_lambda_allows_is_one_the_client_declares() {
    let lambda = LambdaContract::read();
    let declared: BTreeSet<String> = Key::ALL
        .iter()
        .copied()
        .filter(|key| key.scope() == Scope::Linux)
        .filter_map(|key| key.spec().wire.name().map(str::to_owned))
        .collect();

    for name in lambda
        .keys()
        .iter()
        .filter(|name| name.starts_with("linux_"))
    {
        assert!(
            declared.contains(name),
            "the Lambda allows `{name}`, which no client key claims"
        );
    }
}

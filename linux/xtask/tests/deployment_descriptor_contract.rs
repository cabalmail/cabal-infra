//! The deployment-descriptor contract, asserted against Terraform's template.
//!
//! The kit decodes `config.json` into `Deployment`, and its tests decode
//! `cabalmail-kit/tests/fixtures/deployment/descriptor.json` to prove it can.
//! That proof is only as good as the fixture's resemblance to what Terraform
//! actually serves, so this test renders the template's shape and fails if the
//! fixture carries a key the template does not write, or misses one it does.
//! A renamed or removed key in the template then fails here first, and
//! correcting the fixture fails the kit's decode test if the client depended
//! on it.
//!
//! The template writes `domains` as one interpolation, so the shape of its
//! entries comes from the `domains` module's output instead, and is checked
//! against that.

use std::collections::BTreeSet;

use serde_json::Value;

mod support;

const TEMPLATE: &str = "terraform/infra/modules/app/templates/config.js.tftpl";
const DOMAINS_OUTPUT: &str = "terraform/infra/modules/domains/outputs.tf";

fn fixture() -> Value {
    let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../cabalmail-kit/tests/fixtures/deployment/descriptor.json");
    let text = std::fs::read_to_string(&path)
        .unwrap_or_else(|error| panic!("reading {}: {error}", path.display()));
    serde_json::from_str(&text).expect("the fixture is JSON")
}

/// The template with every interpolation replaced by a stand-in: a quoted
/// `"${name}"` keeps its quotes and becomes a string, and a bare
/// `${jsonencode(...)}` becomes `null`. What is left is JSON with the
/// template's keys, which is the part of it this test is about.
fn rendered_template() -> Value {
    let path = support::repo_input(TEMPLATE);
    let text = std::fs::read_to_string(&path)
        .unwrap_or_else(|error| panic!("reading {}: {error}", path.display()));

    let mut rendered = String::new();
    let mut rest = text.as_str();
    while let Some(start) = rest.find("${") {
        let end = rest[start..]
            .find('}')
            .map(|offset| start + offset)
            .unwrap_or_else(|| panic!("{TEMPLATE} has an unterminated interpolation"));
        rendered.push_str(&rest[..start]);
        if rendered.ends_with('"') {
            rendered.push_str("interpolated");
        } else {
            rendered.push_str("null");
        }
        rest = &rest[end + 1..];
    }
    rendered.push_str(rest);

    serde_json::from_str(&rendered)
        .unwrap_or_else(|error| panic!("{TEMPLATE} does not render to JSON: {error}"))
}

/// Every key path the two documents disagree on, descending wherever both
/// sides hold an object.
fn differences(template: &Value, fixture: &Value, prefix: &str, found: &mut Vec<String>) {
    let (Value::Object(template), Value::Object(fixture)) = (template, fixture) else {
        return;
    };
    let template_keys: BTreeSet<&String> = template.keys().collect();
    let fixture_keys: BTreeSet<&String> = fixture.keys().collect();
    for key in template_keys.difference(&fixture_keys) {
        found.push(format!(
            "{prefix}{key} is written by Terraform but missing from the fixture"
        ));
    }
    for key in fixture_keys.difference(&template_keys) {
        found.push(format!(
            "{prefix}{key} is in the fixture but Terraform does not write it"
        ));
    }
    for key in template_keys.intersection(&fixture_keys) {
        differences(
            &template[key.as_str()],
            &fixture[key.as_str()],
            &format!("{prefix}{key}."),
            found,
        );
    }
}

#[test]
fn the_fixture_has_the_keys_terraform_writes() {
    let mut found = Vec::new();
    differences(&rendered_template(), &fixture(), "", &mut found);
    assert!(
        found.is_empty(),
        "cabalmail-kit/tests/fixtures/deployment/descriptor.json has drifted from \
         {TEMPLATE}:\n  {}",
        found.join("\n  ")
    );
}

/// The comparison descends into nested objects, so a drift inside
/// `cognitoConfig.poolData` is caught as well as one at the top.
#[test]
fn a_nested_difference_is_reported_by_its_path() {
    let template = serde_json::json!({"a": {"b": {"c": 1}}});
    let fixture = serde_json::json!({"a": {"b": {"d": 1}}});
    let mut found = Vec::new();
    differences(&template, &fixture, "", &mut found);
    assert_eq!(
        found,
        [
            "a.b.c is written by Terraform but missing from the fixture",
            "a.b.d is in the fixture but Terraform does not write it",
        ]
    );
}

/// The key set of every object literal inside the `domains` module's `locals`
/// block — one per source of mail domains, each of which becomes an entry of
/// the descriptor's `domains` array. Keys are the quoted names assigned with
/// `=`, which is how that file spells them.
fn domain_entry_shapes() -> Vec<BTreeSet<String>> {
    let path = support::repo_input(DOMAINS_OUTPUT);
    let text = std::fs::read_to_string(&path)
        .unwrap_or_else(|error| panic!("reading {}: {error}", path.display()));
    let locals_start = text
        .find("locals {")
        .unwrap_or_else(|| panic!("{DOMAINS_OUTPUT} has no locals block"));
    let locals_end = text[locals_start..]
        .find("\noutput ")
        .map_or(text.len(), |offset| locals_start + offset);
    let locals = &text[locals_start..locals_end];

    let mut shapes = Vec::new();
    let mut rest = locals;
    while let Some(start) = rest.find(": {") {
        let body_start = start + ": {".len();
        let body_end = rest[body_start..]
            .find('}')
            .map(|offset| body_start + offset)
            .unwrap_or_else(|| panic!("{DOMAINS_OUTPUT} has an unterminated object"));
        let keys = rest[body_start..body_end]
            .lines()
            .filter_map(|line| {
                let line = line.trim();
                let (name, _) = line.split_once('=')?;
                let name = name.trim();
                let name = name.strip_prefix('"')?.strip_suffix('"')?;
                Some(name.to_owned())
            })
            .collect();
        shapes.push(keys);
        rest = &rest[body_end..];
    }
    shapes
}

#[test]
fn every_fixture_domain_has_the_keys_the_domains_module_writes() {
    let shapes = domain_entry_shapes();
    assert!(
        !shapes.is_empty() && shapes.iter().all(|shape| !shape.is_empty()),
        "found no object literals in {DOMAINS_OUTPUT}'s locals: {shapes:?}"
    );
    let fixture = fixture();
    let entries = fixture["domains"]
        .as_array()
        .expect("the fixture's domains is an array");
    assert!(!entries.is_empty(), "the fixture has no domains to compare");

    for shape in &shapes {
        for (index, entry) in entries.iter().enumerate() {
            let keys: BTreeSet<String> = entry
                .as_object()
                .expect("each fixture domain is an object")
                .keys()
                .cloned()
                .collect();
            assert_eq!(
                &keys, shape,
                "fixture domains[{index}] has drifted from {DOMAINS_OUTPUT}"
            );
        }
    }
}

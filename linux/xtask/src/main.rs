//! `cargo xtask` — one deterministic spelling per build operation, shared by
//! humans and CI.
//!
//! The subcommands are declared here so the vocabulary is fixed; their
//! implementations land in Phase 1, work item 5.

use std::process::ExitCode;

/// Every subcommand `cargo xtask` will answer to, with its one-line purpose.
const SUBCOMMANDS: &[(&str, &str)] = &[
    (
        "sync-vendored",
        "materialize marked + turndown from react/admin/node_modules",
    ),
    (
        "ci",
        "fmt --check, clippy -D warnings, kit tests, app tests — in CI's order",
    ),
    (
        "package",
        "build a distribution package in a container and lint it",
    ),
    (
        "smoke",
        "install the built package, launch it headless, assert startup",
    ),
    (
        "fixtures",
        "regenerate golden API fixtures from a live stage deployment",
    ),
];

fn main() -> ExitCode {
    let Some(command) = std::env::args().nth(1) else {
        usage();
        return ExitCode::FAILURE;
    };

    match command.as_str() {
        "-h" | "--help" | "help" => {
            usage();
            ExitCode::SUCCESS
        }
        name if SUBCOMMANDS.iter().any(|(known, _)| *known == name) => {
            eprintln!(
                "xtask: `{name}` is declared but not implemented yet \
                 (Phase 1, work item 5)."
            );
            ExitCode::FAILURE
        }
        name => {
            eprintln!("xtask: unknown subcommand `{name}`.");
            usage();
            ExitCode::FAILURE
        }
    }
}

fn usage() {
    eprintln!("usage: cargo xtask <subcommand>\n");
    let width = SUBCOMMANDS
        .iter()
        .map(|(name, _)| name.len())
        .max()
        .unwrap_or(0);
    for (name, purpose) in SUBCOMMANDS {
        eprintln!("  {name:width$}  {purpose}");
    }
}

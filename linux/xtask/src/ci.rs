//! `cargo xtask ci` — everything CI runs, in CI's order.
//!
//! There is one list of steps and it lives here, so the pre-push gate and the
//! workflow cannot drift apart: `.github/workflows/linux.yml` runs these same
//! steps rather than restating the commands in YAML. A developer runs the whole
//! list with `cargo xtask ci`; the workflow gives each step its own job and
//! names it with `cargo xtask ci --step <name>`, so a failure is attributed to
//! a job rather than buried in one long log. `--list` prints the names, which
//! is what the drift test in `tests/workflow_contract.rs` compares the workflow
//! against.
//!
//! Fail-fast is deliberate. This is a gate, and the first failure is the one
//! worth reading; a run that continues past a formatting failure just buries it
//! under a clippy log.

use std::path::Path;

use crate::process::{self, Step};

/// What the app tests have to work with, since `cabalmail-gtk`'s widget tests
/// need a display and the rest of the workspace does not.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Display {
    /// A session is already running — Wayland or X11. A developer's machine.
    Session,
    /// No session, but `xvfb-run` can supply one. This is CI.
    Xvfb,
    /// Neither. The widget tests skip themselves and say so; everything else in
    /// the app crate still runs, so this is a warning rather than a failure.
    None,
}

/// Runs the gate. `only` narrows it to the single step of that name, which is
/// how each CI job runs exactly one of them.
pub fn run(workspace: &Path, only: Option<&str>) -> Result<(), String> {
    let display = detect_display();
    let mut steps: Vec<Step> = match only {
        Some(name) => plan(&cargo(), display)
            .into_iter()
            .filter(|step| step.label == name)
            .collect(),
        None => plan(&cargo(), display),
    };

    // A selection that matched nothing would run zero steps and report success
    // — a CI job that tested nothing and went green. `parse` rejects an unknown
    // name before we get here; this is the backstop for the day something else
    // calls in.
    if steps.is_empty() {
        return Err(format!(
            "no ci step matched `{}`. Steps: {}",
            only.unwrap_or(""),
            step_names().join(", ")
        ));
    }

    // Two steps run a separate binary rather than a toolchain component, so
    // the gate has to say what it does when one is absent. In CI, nothing: a
    // check that quietly did not run is the failure this whole file is
    // arranged against. On a developer's machine a whole-gate run says so and
    // carries on, the same bargain the widget tests strike with a missing
    // display — but `--step <name>` is a request to run that step and nothing
    // else, so it fails rather than reporting success having run no step at
    // all.
    for tool in EXTERNAL_TOOLS {
        if !steps.iter().any(|step| step.label == tool.step) || on_path(tool.binary) {
            continue;
        }
        let shortfall = format!("`{}` is not on PATH, so {}", tool.binary, tool.shortfall);
        let remedy = format!("cargo install --locked {}@{}", tool.binary, tool.pin);
        if missing_tool_is_fatal(in_ci(), only.is_some()) {
            return Err(format!("{shortfall}. Install it with `{remedy}`."));
        }
        eprintln!(
            "[xtask] ci: {shortfall}. `{remedy}` to run it here; CI runs it on \
             every push."
        );
        steps.retain(|step| step.label != tool.step);
    }

    // Being on PATH is not the same as being the version CI reads. A
    // distribution package satisfies the check above and can be years ahead:
    // the same advisory database read under different rules, or a coverage
    // number computed differently, with nothing saying so. The pin is written
    // in four places and held together by a test; this is what holds the
    // *binary* to it.
    for tool in EXTERNAL_TOOLS {
        if !steps.iter().any(|step| step.label == tool.step) {
            continue;
        }
        let Some(found) = installed_version(tool.binary) else {
            continue;
        };
        if found == tool.pin {
            continue;
        }
        let mismatch = format!(
            "`{}` on PATH is {found}, and this gate is calibrated against {}",
            tool.binary, tool.pin
        );
        if missing_tool_is_fatal(in_ci(), only.is_some()) {
            return Err(format!(
                "{mismatch}. A result read against different rules than CI's is \
                 worse than no result. Install the pinned version, or move the \
                 pin deliberately."
            ));
        }
        eprintln!("[xtask] ci: {mismatch}, so this result and CI's are not comparable.");
    }

    if steps.iter().any(|step| step.label == APP_TESTS) {
        let shortfall = "no display server and no xvfb-run — the widget tests will skip themselves";
        if missing_display_is_fatal(display, in_ci()) {
            return Err(format!(
                "{shortfall}, and CI is set. A job that tests no widgets and goes \
                 green is worse than a red one: install xvfb and xauth, and make \
                 sure `xvfb-run` is on PATH."
            ));
        }
        if display == Display::None {
            eprintln!("[xtask] ci: {shortfall}. Install xorg-server-xvfb to run them.");
        }
    }

    let total = steps.len();
    for (index, step) in steps.iter().enumerate() {
        println!("[xtask] ci: step {} of {total}", index + 1);
        process::run(step, workspace)?;
    }
    println!("[xtask] ci: {total} steps passed");
    Ok(())
}

/// Every step name, in the order the gate runs them.
pub fn step_names() -> Vec<&'static str> {
    plan("cargo", Display::None)
        .into_iter()
        .map(|step| step.label)
        .collect()
}

/// The cargo that invoked us. Cargo sets `$CARGO` for its subprocesses, so
/// `cargo +nightly xtask ci` runs its steps under the same toolchain the
/// caller asked for rather than silently reverting to the default.
fn cargo() -> String {
    std::env::var("CARGO").unwrap_or_else(|_| "cargo".to_owned())
}

/// The one step name that cares whether there is a display to draw on.
const APP_TESTS: &str = "app-tests";

/// The steps run by a binary that is not part of the toolchain.
const SUPPLY_CHAIN: &str = "supply-chain";
const COVERAGE: &str = "coverage";

/// The version each of those binaries this gate is calibrated against. A
/// result is only comparable between a developer's run and CI's while both
/// read the same rules, so the instruction printed here names the version the
/// workflows install rather than whatever `cargo install` resolves today.
/// `xtask/tests/workflow_contract.rs` fails if one of these and the two
/// workflows and the README stop agreeing.
const CARGO_DENY_PIN: &str = "0.20.2";
const CARGO_LLVM_COV_PIN: &str = "0.9.1";

/// The share of `cabalmail-kit`'s lines the tests have to reach.
///
/// Set from what the suite measured when the floor landed — 95.75% — with
/// enough margin that ordinary work does not redden CI on a line or two.
///
/// What it catches is a broad regression: tests deleted, a suite that stopped
/// running, a large module landing untested. What it does **not** catch is a
/// small untested module, which can sit under a crate-wide figure without
/// moving it — the arithmetic is unavoidable in any whole-crate floor. That
/// case is a reviewer's to catch, and the floor's job is to re-set upward each
/// time the measured figure moves up and stays there. It is a floor, not a
/// target.
const KIT_LINE_COVERAGE_FLOOR: &str = "90";

/// A binary the gate runs that `rustup` does not install.
struct ExternalTool {
    /// The step that needs it.
    step: &'static str,
    /// The binary, as `cargo install` and `PATH` both spell it.
    binary: &'static str,
    /// The version the workflows install.
    pin: &'static str,
    /// What goes unchecked without it, phrased to follow "is not on PATH, so".
    shortfall: &'static str,
}

const EXTERNAL_TOOLS: &[ExternalTool] = &[
    ExternalTool {
        step: SUPPLY_CHAIN,
        binary: "cargo-deny",
        pin: CARGO_DENY_PIN,
        shortfall: "the licence and advisory policy is unchecked",
    },
    ExternalTool {
        step: COVERAGE,
        binary: "cargo-llvm-cov",
        pin: CARGO_LLVM_COV_PIN,
        shortfall: "the kit's coverage floor is unenforced",
    },
];

/// Whether starting the app tests with nothing to draw on should stop the run
/// rather than warn. On a developer's machine a skip is the right answer — a
/// bare SSH session should still get the rest of the app crate's tests. In CI
/// there is no such thing as an acceptable skip: it means the job installed no
/// virtual display and would report success having exercised no widget.
fn missing_display_is_fatal(display: Display, in_ci: bool) -> bool {
    display == Display::None && in_ci
}

/// Whether a missing external tool should stop the run rather than warn. In CI
/// there is no acceptable skip. Naming the step explicitly is the other case:
/// it asks for that step and nothing else, and answering it with a warning and
/// a successful exit would be a job that reported success having run nothing.
fn missing_tool_is_fatal(in_ci: bool, selected_by_name: bool) -> bool {
    in_ci || selected_by_name
}

/// The version of `binary` on PATH, or `None` when it will not say.
///
/// Every one of these is a cargo subcommand, so it is asked the way cargo
/// would: `cargo <subcommand> --version` prints `<name> <version>`. A binary
/// that answers in some other shape is left alone rather than guessed at —
/// refusing to run over an unparsed version string would be a gate that failed
/// for its own reasons.
fn installed_version(binary: &str) -> Option<String> {
    let subcommand = binary.strip_prefix("cargo-")?;
    let output = std::process::Command::new(cargo())
        .args([subcommand, "--version"])
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    let printed = String::from_utf8(output.stdout).ok()?;
    let version = printed.split_whitespace().nth(1)?;
    version
        .chars()
        .all(|character| character.is_ascii_digit() || character == '.')
        .then(|| version.to_owned())
}

/// Every CI provider sets this; GitHub Actions sets it to `true`.
fn in_ci() -> bool {
    std::env::var_os("CI").is_some_and(|value| !value.is_empty())
}

/// The steps, in order. Pure so the order and the flags are testable without
/// running a two-minute build.
///
/// A step's label is also the name a CI job selects it by, so the labels are
/// single words: renaming one renames a workflow argument, and the drift test
/// fails until both move together.
fn plan(cargo: &str, display: Display) -> Vec<Step> {
    vec![
        // `fmt` parses rather than resolves, so it is the one step with no
        // `--locked` to give it.
        Step::new("format", cargo, ["fmt", "--all", "--check"]),
        Step::new(
            "clippy",
            cargo,
            [
                "clippy",
                "--locked",
                "--workspace",
                "--all-targets",
                "--",
                "-D",
                "warnings",
            ],
        ),
        Step::new(
            "kit-tests",
            cargo,
            ["test", "--locked", "-p", "cabalmail-kit"],
        ),
        Step::new(
            "workspace-checks",
            cargo,
            ["test", "--locked", "-p", "xtask"],
        ),
        app_tests(cargo, display),
        // The kit's tests again, this time instrumented, so the floor is
        // measured over the same suite `kit-tests` runs rather than over a
        // selection of it. `--summary-only` because a per-function table is
        // several hundred lines of log for a number the job either passes or
        // fails on; the job that failed prints the per-file summary above it.
        Step::new(
            COVERAGE,
            cargo,
            [
                "llvm-cov",
                "--locked",
                "-p",
                "cabalmail-kit",
                "--summary-only",
                "--fail-under-lines",
                KIT_LINE_COVERAGE_FLOOR,
            ],
        ),
        // Last because it is the one step that needs the network: it fetches
        // the RustSec advisory database. A run that fails for want of a
        // network connection should do it after everything local has had its
        // say. `--locked` goes before the subcommand — it is cargo-deny's own
        // flag, not `check`'s.
        Step::new(SUPPLY_CHAIN, cargo, ["deny", "--locked", "check"]),
    ]
}

/// The app tests, wrapped in `xvfb-run` when that is the only display going.
/// `-a` picks a free server number, which matters on a runner where two jobs
/// can overlap.
///
/// `--show-output` because libtest replays a passing test's output only for
/// failures, and a widget test that skips itself passes. Without it the reason
/// the run drew nothing is captured and thrown away — for a reader and for the
/// workflow step that greps the log for exactly that.
fn app_tests(cargo: &str, display: Display) -> Step {
    let test = [
        "test",
        "--locked",
        "-p",
        "cabalmail-gtk",
        "--",
        "--show-output",
    ];
    match display {
        Display::Xvfb => {
            let mut args = vec!["-a".to_owned(), cargo.to_owned()];
            args.extend(test.iter().map(|arg| (*arg).to_owned()));
            Step::new(APP_TESTS, "xvfb-run", args)
        }
        Display::Session | Display::None => Step::new(APP_TESTS, cargo, test),
    }
}

fn detect_display() -> Display {
    let running = |name: &str| std::env::var_os(name).is_some_and(|value| !value.is_empty());
    classify(
        running("WAYLAND_DISPLAY") || running("DISPLAY"),
        on_path("xvfb-run"),
    )
}

/// A session in hand always wins: `xvfb-run` inside a desktop session would
/// hide the tests from the display they are meant to exercise.
fn classify(has_session: bool, has_xvfb: bool) -> Display {
    match (has_session, has_xvfb) {
        (true, _) => Display::Session,
        (false, true) => Display::Xvfb,
        (false, false) => Display::None,
    }
}

fn on_path(program: &str) -> bool {
    let Some(path) = std::env::var_os("PATH") else {
        return false;
    };
    std::env::split_paths(&path).any(|dir| dir.join(program).is_file())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn labels(display: Display) -> Vec<&'static str> {
        plan("cargo", display).iter().map(|s| s.label).collect()
    }

    /// Cheap checks first: a formatting failure should cost seconds, not the
    /// whole test suite.
    #[test]
    fn the_plan_runs_in_cis_order() {
        assert_eq!(
            labels(Display::Session),
            vec![
                "format",
                "clippy",
                "kit-tests",
                "workspace-checks",
                "app-tests",
                "coverage",
                "supply-chain"
            ]
        );
    }

    /// What `--step` and the workflow's job arguments are matched against.
    #[test]
    fn the_step_names_are_the_plans_labels() {
        assert_eq!(step_names(), labels(Display::None));
    }

    /// A name with a space in it would need quoting in the workflow, where it
    /// is an argument. Cheaper to keep the names shell-plain.
    #[test]
    fn every_step_name_is_a_single_word() {
        for name in step_names() {
            assert!(
                !name.is_empty()
                    && name
                        .bytes()
                        .all(|byte| byte.is_ascii_lowercase() || byte == b'-'),
                "`{name}` is not a lowercase, hyphenated single word"
            );
        }
    }

    /// The reason the toolchain is pinned exactly. If this ever softens, a new
    /// Rust release reddens CI on lints nobody wrote code against — but at
    /// least it will have been a deliberate edit.
    #[test]
    fn clippy_denies_warnings_across_every_target() {
        let step = plan("cargo", Display::Session)
            .into_iter()
            .find(|step| step.label == "clippy")
            .expect("the plan lints");
        assert_eq!(
            step.command_line(),
            "cargo clippy --locked --workspace --all-targets -- -D warnings"
        );
    }

    /// `Cargo.lock` is committed because distro packaging builds offline
    /// against vendored crates. Without `--locked`, a dependency bump whose
    /// lock update was never committed resolves silently in CI and passes,
    /// then fails in `makepkg`'s `--frozen --offline` build — or worse, ships
    /// versions nothing verified. `fmt` is exempt: it never resolves.
    ///
    /// Necessary but not sufficient on its own: cargo resolves the lock before
    /// it builds the launcher these steps run inside, so the `xtask` alias
    /// needs its own `--locked`. That is asserted in
    /// `tests/workspace_invariants.rs`.
    #[test]
    fn every_resolving_step_refuses_to_update_the_lock_file() {
        for step in plan("cargo", Display::Xvfb) {
            if step.label == "format" {
                assert!(!step.command_line().contains("--locked"));
                continue;
            }
            assert!(
                step.args.iter().any(|arg| arg == "--locked"),
                "`{}` may rewrite Cargo.lock: {}",
                step.label,
                step.command_line()
            );
        }
    }

    #[test]
    fn the_app_tests_run_under_xvfb_only_when_there_is_no_session() {
        let of = |display| {
            plan("cargo", display)
                .into_iter()
                .find(|step| step.label == APP_TESTS)
                .expect("the plan tests the app")
                .command_line()
        };
        assert_eq!(
            of(Display::Xvfb),
            "xvfb-run -a cargo test --locked -p cabalmail-gtk -- --show-output"
        );
        assert_eq!(
            of(Display::Session),
            "cargo test --locked -p cabalmail-gtk -- --show-output"
        );
        assert_eq!(
            of(Display::None),
            "cargo test --locked -p cabalmail-gtk -- --show-output"
        );
    }

    /// libtest captures a passing test's output and replays it only on
    /// failure, and a widget test that skips itself passes. Without this flag
    /// the skip message never reaches the log, so the workflow step that greps
    /// for it can never fire.
    #[test]
    fn the_app_tests_print_what_a_passing_test_said() {
        for display in [Display::Session, Display::Xvfb, Display::None] {
            assert!(
                app_tests("cargo", display)
                    .args
                    .iter()
                    .any(|arg| arg == "--show-output"),
                "a skipped widget test would be silent under {display:?}"
            );
        }
    }

    /// The failure this exists for: `xvfb-run` missing from a container's
    /// PATH. The step falls back to a plain `cargo test`, every widget test
    /// skips itself, and the job goes green having tested no widget. A
    /// developer on a bare SSH session gets the warning instead.
    #[test]
    fn a_ci_run_with_no_display_at_all_is_a_failure_rather_than_a_skip() {
        assert!(missing_display_is_fatal(Display::None, true));
        assert!(!missing_display_is_fatal(Display::None, false));
        for display in [Display::Session, Display::Xvfb] {
            assert!(!missing_display_is_fatal(display, true));
            assert!(!missing_display_is_fatal(display, false));
        }
    }

    /// The failure mode this guards is a job that runs nothing and reports
    /// success. `parse` rejects an unknown step name first; this is what makes
    /// the run itself refuse rather than print "0 steps passed".
    #[test]
    fn a_selection_that_matches_nothing_is_an_error() {
        let error = run(Path::new("."), Some("no-such-step")).expect_err("nothing to run");
        assert!(error.contains("no-such-step"), "{error}");
        for name in step_names() {
            assert!(
                error.contains(name),
                "the error should list `{name}`: {error}"
            );
        }
    }

    /// The floor is a number the step passes to a tool, so it has to be one
    /// the tool reads as a percentage. A typo'd `"90%"` or `"ninety"` would
    /// fail the step for the wrong reason, on every run.
    #[test]
    fn the_coverage_floor_is_a_percentage() {
        let floor: u32 = KIT_LINE_COVERAGE_FLOOR
            .parse()
            .expect("the coverage floor is a plain integer");
        assert!(
            (1..=100).contains(&floor),
            "a floor of {floor} is not a share of anything"
        );
    }

    /// The floor is measured over the same tests `kit-tests` runs. A coverage
    /// step scoped to some other package would report a number about code the
    /// floor was never set from.
    #[test]
    fn the_coverage_step_measures_the_kit() {
        let step = plan("cargo", Display::Session)
            .into_iter()
            .find(|step| step.label == COVERAGE)
            .expect("the plan measures coverage");
        assert_eq!(
            step.command_line(),
            format!(
                "cargo llvm-cov --locked -p cabalmail-kit --summary-only \
                 --fail-under-lines {KIT_LINE_COVERAGE_FLOOR}"
            )
            .replace("\n", "")
            .split_whitespace()
            .collect::<Vec<_>>()
            .join(" ")
        );
    }

    /// The pins are what a developer is told to install and what CI installs.
    /// A gate that accepted any version on PATH would read a distribution
    /// package's rules and report them as CI's.
    #[test]
    fn the_installed_version_is_read_from_the_binary_itself() {
        for tool in EXTERNAL_TOOLS {
            let Some(found) = installed_version(tool.binary) else {
                continue;
            };
            assert!(
                found.split('.').count() == 3,
                "`{}` reported `{found}`, which is not an x.y.z version",
                tool.binary
            );
        }
        assert_eq!(installed_version("cargo"), None, "not a cargo subcommand");
        assert_eq!(installed_version("cargo-no-such-tool"), None);
    }

    /// Both external binaries answer to the same policy, and each names the
    /// step it belongs to. A tool whose step does not exist would never be
    /// checked for, and its step would fail with "not on PATH" in CI.
    #[test]
    fn every_external_tool_names_a_step_the_plan_runs() {
        assert!(!EXTERNAL_TOOLS.is_empty());
        for tool in EXTERNAL_TOOLS {
            assert!(
                step_names().contains(&tool.step),
                "`{}` is needed by `{}`, which the plan does not run",
                tool.binary,
                tool.step
            );
            assert_eq!(
                tool.pin.split('.').count(),
                3,
                "`{}` is pinned to `{}`, which is not an exact x.y.z version",
                tool.binary,
                tool.pin
            );
        }
    }

    /// The policy `cargo deny` is run under. A whole-gate run on a machine
    /// without the binary warns and moves on; CI does not, and neither does a
    /// run that asked for this step by name — that one would otherwise print
    /// "0 steps passed" and exit 0, which is the shape of every silent failure
    /// this file is arranged against.
    #[test]
    fn a_missing_tool_stops_ci_and_a_named_step_but_not_a_local_gate_run() {
        assert!(missing_tool_is_fatal(true, false));
        assert!(missing_tool_is_fatal(true, true));
        assert!(missing_tool_is_fatal(false, true));
        assert!(!missing_tool_is_fatal(false, false));
    }

    /// `--locked` is cargo-deny's own flag and has to precede the subcommand;
    /// after it, `check` rejects it as an unknown argument.
    #[test]
    fn the_supply_chain_step_locks_before_it_names_the_subcommand() {
        let step = plan("cargo", Display::Session)
            .into_iter()
            .find(|step| step.label == SUPPLY_CHAIN)
            .expect("the plan checks the dependency graph");
        assert_eq!(step.command_line(), "cargo deny --locked check");
    }

    /// A session in hand beats a virtual one, and `xvfb-run` is only reached
    /// for when there is nothing else.
    #[test]
    fn a_running_session_is_preferred_to_xvfb() {
        assert_eq!(classify(true, true), Display::Session);
        assert_eq!(classify(true, false), Display::Session);
        assert_eq!(classify(false, true), Display::Xvfb);
        assert_eq!(classify(false, false), Display::None);
    }

    /// `cargo +1.97.1 xtask ci` must not run its steps under the default
    /// toolchain — every cargo step goes through the caller's binary.
    #[test]
    fn every_cargo_step_uses_the_cargo_that_invoked_us() {
        for step in plan("/opt/rust/bin/cargo", Display::Xvfb) {
            assert!(
                step.command_line().contains("/opt/rust/bin/cargo"),
                "`{}` does not use the caller's cargo: {}",
                step.label,
                step.command_line()
            );
        }
    }
}

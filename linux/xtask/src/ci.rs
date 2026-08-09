//! `cargo xtask ci` — everything CI runs, in CI's order.
//!
//! There is one list of steps and it lives here, so the pre-push gate and the
//! workflow cannot drift apart: `linux.yml` (Phase 2) runs these same
//! subcommands rather than restating the commands in YAML.
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

pub fn run(workspace: &Path) -> Result<(), String> {
    let display = detect_display();
    if display == Display::None {
        eprintln!(
            "[xtask] ci: no display server and no xvfb-run — the widget tests \
             will skip themselves. Install xorg-server-xvfb to run them."
        );
    }

    let steps = plan(&cargo(), display);
    let total = steps.len();
    for (index, step) in steps.iter().enumerate() {
        println!("[xtask] ci: step {} of {total}", index + 1);
        process::run(step, workspace)?;
    }
    println!("[xtask] ci: {total} steps passed");
    Ok(())
}

/// The cargo that invoked us. Cargo sets `$CARGO` for its subprocesses, so
/// `cargo +nightly xtask ci` runs its steps under the same toolchain the
/// caller asked for rather than silently reverting to the default.
fn cargo() -> String {
    std::env::var("CARGO").unwrap_or_else(|_| "cargo".to_owned())
}

/// The steps, in order. Pure so the order and the flags are testable without
/// running a two-minute build.
fn plan(cargo: &str, display: Display) -> Vec<Step> {
    vec![
        Step::new("format", cargo, ["fmt", "--all", "--check"]),
        Step::new(
            "clippy",
            cargo,
            [
                "clippy",
                "--workspace",
                "--all-targets",
                "--",
                "-D",
                "warnings",
            ],
        ),
        Step::new("kit tests", cargo, ["test", "-p", "cabalmail-kit"]),
        Step::new("workspace checks", cargo, ["test", "-p", "xtask"]),
        app_tests(cargo, display),
    ]
}

/// The app tests, wrapped in `xvfb-run` when that is the only display going.
/// `-a` picks a free server number, which matters on a runner where two jobs
/// can overlap.
fn app_tests(cargo: &str, display: Display) -> Step {
    let test = ["test", "-p", "cabalmail-gtk"];
    match display {
        Display::Xvfb => {
            let mut args = vec!["-a".to_owned(), cargo.to_owned()];
            args.extend(test.iter().map(|arg| (*arg).to_owned()));
            Step::new("app tests", "xvfb-run", args)
        }
        Display::Session | Display::None => Step::new("app tests", cargo, test),
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
                "kit tests",
                "workspace checks",
                "app tests"
            ]
        );
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
            "cargo clippy --workspace --all-targets -- -D warnings"
        );
    }

    #[test]
    fn the_app_tests_run_under_xvfb_only_when_there_is_no_session() {
        let of = |display| {
            plan("cargo", display)
                .into_iter()
                .find(|step| step.label == "app tests")
                .expect("the plan tests the app")
                .command_line()
        };
        assert_eq!(of(Display::Xvfb), "xvfb-run -a cargo test -p cabalmail-gtk");
        assert_eq!(of(Display::Session), "cargo test -p cabalmail-gtk");
        assert_eq!(of(Display::None), "cargo test -p cabalmail-gtk");
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

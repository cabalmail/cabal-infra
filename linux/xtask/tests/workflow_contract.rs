//! The CI workflow and `cargo xtask ci` cannot drift.
//!
//! The gate is one list of steps, in `xtask/src/ci.rs`. `linux.yml` gives each
//! step its own job so a failure names itself, which only works while the two
//! agree: a job naming a step that no longer exists would run nothing and pass,
//! and a step no job runs would be enforced before every push and never in CI.
//! Both are silent failures, so they are asserted here.
//!
//! The workflow is read as text, the way `lambda_preferences_contract.rs` reads
//! the Lambda: the shapes involved are job headers and one argument, and adding
//! a YAML parser to the workspace to find them would cost more than it explains.

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};
use std::process::Command;

mod support;

/// How a job selects its step. Also the string the test scans for.
const STEP_FLAG: &str = "cargo xtask ci --step ";

/// The image that defines the API floor — Ubuntu 24.04 LTS, GTK 4.14.
const FLOOR_IMAGE: &str = "image: ubuntu:24.04";

/// Steps whose job must run on the floor image. `clippy` compiles the whole
/// workspace (`--all-targets`), so it is the build that proves newer API does
/// not sneak in; `app-tests` exercises the widgets against the floor's
/// libraries. Running either on whatever `ubuntu-latest` currently is would
/// quietly stop enforcing the floor the first time GitHub rolls the label.
const STEPS_ON_THE_FLOOR: &[&str] = &["clippy", "app-tests"];

/// How a job installs the one binary the gate runs that is not part of the
/// toolchain. Both workflows install it, and they have to install the same one.
const DENY_TOOL: &str = "tool: cargo-deny@";

/// How `xtask/src/ci.rs` names the version it tells a developer to install,
/// and how `linux/README.md` spells the same instruction. Four files carry
/// that version and none can see the others.
const DENY_PIN_CONST: &str = "const CARGO_DENY_PIN: &str = \"";
const DENY_INSTALL: &str = "cargo install --locked cargo-deny@";

/// What a widget test prints when it has nothing to draw on, and what the
/// app-test job greps its log for. It is written in two places that cannot see
/// each other - a Rust source file and a YAML file - so it is pinned here.
const SKIP_MARKER: &str = "skipping: no display server";

fn repo_root() -> PathBuf {
    support::repo_root()
}

fn workflow() -> String {
    let path = support::repo_input(".github/workflows/linux.yml");
    std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("reading {}: {e}", path.display()))
}

/// The pull-request gate. `lint.yml`'s `rust` job runs the same
/// `cargo xtask ci`, which is why its filter is held to the same rule.
fn lint_workflow() -> String {
    let path = support::repo_input(".github/workflows/lint.yml");
    std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("reading {}: {e}", path.display()))
}

/// The quoted entries under `rust:` in lint.yml's `dorny/paths-filter` block,
/// which is what decides whether the Rust gate runs on a pull request.
fn rust_filter_paths(lint: &str) -> Vec<String> {
    let (_, below) = lint
        .split_once("\n          rust:\n")
        .expect("lint.yml filters a `rust` area");
    let mut found = Vec::new();
    for line in below.lines() {
        let trimmed = line.trim();
        if let Some(rest) = trimmed.strip_prefix("- '") {
            found.push(
                rest.strip_suffix('\'')
                    .expect("a filter entry is quoted")
                    .to_owned(),
            );
            continue;
        }
        // A comment belongs to the block it sits in; anything else ends it.
        if !trimmed.is_empty() && !trimmed.starts_with('#') {
            break;
        }
    }
    assert!(!found.is_empty(), "lint.yml's rust filter matches nothing");
    found
}

/// Whether `path` is a file a job could run. Unix-only, like everything else
/// in this workspace.
fn executable(path: &Path) -> bool {
    use std::os::unix::fs::PermissionsExt as _;

    std::fs::metadata(path)
        .is_ok_and(|metadata| metadata.is_file() && metadata.permissions().mode() & 0o111 != 0)
}

/// One job of the workflow: its name and the lines under it.
struct Job {
    name: String,
    body: String,
}

impl Job {
    /// The steps this job runs, in order.
    fn steps(&self) -> Vec<String> {
        self.body
            .lines()
            .filter_map(|line| line.split_once(STEP_FLAG))
            .filter_map(|(_, rest)| rest.split_whitespace().next())
            .map(str::to_owned)
            .collect()
    }

    fn on_the_floor_image(&self) -> bool {
        self.body.contains(FLOOR_IMAGE)
    }
}

/// Splits the workflow at its job headers: keys indented exactly two spaces,
/// below `jobs:`. Comments and deeper keys are part of whichever job they
/// follow, which is what the assertions want.
fn jobs(workflow: &str) -> Vec<Job> {
    let (_, below) = workflow
        .split_once("\njobs:\n")
        .expect("the workflow declares jobs");

    let mut found: Vec<Job> = Vec::new();
    for line in below.lines() {
        match job_header(line) {
            Some(name) => found.push(Job {
                name,
                body: String::new(),
            }),
            None => {
                if let Some(job) = found.last_mut() {
                    job.body.push_str(line);
                    job.body.push('\n');
                }
            }
        }
    }
    assert!(!found.is_empty(), "no jobs found in the workflow");
    found
}

/// `  some-job:` and nothing else — not `    steps:`, not `  # a comment`.
fn job_header(line: &str) -> Option<String> {
    let name = line.strip_prefix("  ")?.strip_suffix(':')?;
    let plain = !name.is_empty()
        && name
            .bytes()
            .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'-');
    plain.then(|| name.to_owned())
}

/// The step names `cargo xtask ci` declares, asked of the binary itself rather
/// than restated here — a list copied into this test would be one more thing
/// that can drift.
fn declared_steps() -> Vec<String> {
    let output = Command::new(env!("CARGO_BIN_EXE_xtask"))
        .args(["ci", "--list"])
        .output()
        .expect("running `xtask ci --list`");
    assert!(
        output.status.success(),
        "`xtask ci --list` failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    String::from_utf8(output.stdout)
        .expect("the step names are UTF-8")
        .lines()
        .map(str::to_owned)
        .collect()
}

#[test]
fn every_ci_step_has_a_job_that_runs_it() {
    let workflow = workflow();
    let run: Vec<String> = jobs(&workflow).iter().flat_map(Job::steps).collect();

    for step in declared_steps() {
        let times = run.iter().filter(|invoked| **invoked == step).count();
        assert_eq!(
            times, 1,
            "`{step}` is run by {times} jobs in linux.yml; it should be run by exactly one"
        );
    }
}

#[test]
fn no_job_names_a_step_that_does_not_exist() {
    let workflow = workflow();
    let declared: BTreeSet<String> = declared_steps().into_iter().collect();

    for job in jobs(&workflow) {
        for step in job.steps() {
            assert!(
                declared.contains(&step),
                "job `{}` runs `{step}`, which `cargo xtask ci` does not declare. \
                 Steps: {}",
                job.name,
                declared.iter().cloned().collect::<Vec<_>>().join(", ")
            );
        }
    }
}

/// The point of the whole arrangement: CI runs the commands the pre-push gate
/// runs, by name. A job that spelled its own `cargo test` line would pass while
/// diverging from what a developer runs.
#[test]
fn no_job_spells_a_cargo_command_of_its_own() {
    for job in jobs(&workflow()) {
        for line in job.body.lines() {
            let Some((_, rest)) = line.split_once("cargo ") else {
                continue;
            };
            assert!(
                rest.starts_with("xtask "),
                "job `{}` runs cargo directly: {}. Every command CI runs belongs \
                 in the `cargo xtask ci` plan.",
                job.name,
                line.trim()
            );
        }
    }
}

#[test]
fn the_floor_steps_run_on_the_floor_image() {
    let workflow = workflow();
    let jobs = jobs(&workflow);

    for step in STEPS_ON_THE_FLOOR {
        let job = jobs
            .iter()
            .find(|job| job.steps().iter().any(|invoked| invoked == step))
            .unwrap_or_else(|| panic!("no job runs `{step}`"));
        assert!(
            job.on_the_floor_image(),
            "job `{}` runs `{step}` but not in a `{FLOOR_IMAGE}` container, \
             so it no longer enforces the API floor",
            job.name
        );
    }
}

/// The app-test job's last line of defence: a widget test that skips itself
/// still passes, so the job reads the log for the message it printed. Reword
/// that message in `cabalmail-gtk` alone and the grep matches nothing forever
/// after, silently - the job would go green having tested no widget.
#[test]
fn the_skip_message_the_workflow_greps_for_is_the_one_the_tests_print() {
    assert!(
        workflow().contains(SKIP_MARKER),
        "the app-test job no longer looks for `{SKIP_MARKER}`"
    );

    let sources = repo_root().join("linux").join("cabalmail-gtk").join("src");
    let mut printed_in: Vec<PathBuf> = Vec::new();
    for file in rust_sources(&sources) {
        let text = std::fs::read_to_string(&file).expect("a source file is UTF-8");
        if text.contains(SKIP_MARKER) {
            printed_in.push(file);
        }
    }

    assert!(
        !printed_in.is_empty(),
        "no test under {} prints `{SKIP_MARKER}`, so the app-test job's guard \
         can never fire",
        sources.display()
    );
}

/// Every `.rs` file under `dir`, recursively.
fn rust_sources(dir: &Path) -> Vec<PathBuf> {
    let mut found = Vec::new();
    let entries =
        std::fs::read_dir(dir).unwrap_or_else(|e| panic!("reading {}: {e}", dir.display()));
    for entry in entries {
        let path = entry.expect("a directory entry").path();
        if path.is_dir() {
            found.extend(rust_sources(&path));
        } else if path.extension().is_some_and(|extension| extension == "rs") {
            found.push(path);
        }
    }
    found
}

/// Every dependency list the workflow installs from has to exist: a typo'd
/// distro name would fail deep inside a container job, minutes in.
#[test]
fn the_dependency_lists_the_workflow_installs_exist() {
    let workflow = workflow();
    let mut referenced = 0;

    let installer = repo_root()
        .join(".github")
        .join("scripts")
        .join("install-linux-deps.sh");

    for line in workflow.lines() {
        let Some((_, rest)) = line.split_once("install-linux-deps.sh ") else {
            continue;
        };
        assert!(
            executable(&installer),
            "the workflow runs {} but it is missing or not executable",
            installer.display()
        );
        let distro = rest.split_whitespace().next().expect("a distro argument");
        let list = repo_root()
            .join("linux")
            .join("packaging")
            .join("deps")
            .join(format!("{distro}.txt"));
        assert!(
            list.is_file(),
            "the workflow installs `{distro}` dependencies, but {} does not exist",
            list.display()
        );
        referenced += 1;
    }

    assert!(
        referenced > 0,
        "no job installs system dependencies — the app crate cannot build without them"
    );
}

/// The trigger, asserted because the failure mode is silence: a workflow that
/// no longer fires on `linux/**` reports nothing rather than reporting red.
#[test]
fn the_workflow_fires_on_the_client_and_on_itself() {
    let workflow = workflow();
    let triggers = triggers(&workflow);

    for required in [
        "workflow_dispatch:",
        "- main",
        "- stage",
        "- 'linux/**'",
        "- '.github/workflows/linux.yml'",
    ] {
        assert!(
            triggers.contains(required),
            "the workflow's triggers are missing `{required}`"
        );
    }
}

/// Everything outside `linux/` that a job reaches for has to be in the paths
/// filter. A composite action or an install script that can change without
/// running this workflow is a break that lands green and surfaces later, on
/// somebody else's unrelated push - the same drift `check-docker-tier-filters.sh`
/// exists to prevent on the docker side.
#[test]
fn every_file_the_jobs_reach_for_triggers_the_workflow() {
    let workflow = workflow();
    let paths = trigger_paths(&workflow);

    // The jobs only: the `paths:` filter names some of these files itself, and
    // a filter entry is not a job reaching for anything.
    let bodies: String = jobs(&workflow).iter().map(|job| job.body.clone()).collect();

    let mut reached: BTreeSet<String> = BTreeSet::new();
    for line in bodies.lines() {
        let line = line.trim();
        // A local composite action: `uses: ./.github/actions/<name>`.
        if let Some(action) = line.strip_prefix("uses: ./") {
            reached.insert(format!("{}/action.yml", action.trim_end()));
        }
        // A repository script a step runs.
        if let Some((_, rest)) = line.split_once(".github/scripts/") {
            let script = rest.split_whitespace().next().expect("a script name");
            reached.insert(format!(".github/scripts/{script}"));
        }
    }

    assert!(
        !reached.is_empty(),
        "no repository files found in the workflow - has the scan stopped matching?"
    );

    for file in reached {
        assert!(
            repo_root().join(&file).is_file(),
            "the workflow reaches for {file}, which does not exist"
        );
        assert!(
            paths.iter().any(|pattern| covers(pattern, &file)),
            "the workflow reaches for {file} but does not fire on changes to it. \
             Add it to the `paths:` filter."
        );
    }
}

/// The other half of the coverage rule, and the half a job scan cannot see: a
/// test that reads a file outside `linux/` is silent unless the workflows that
/// run it fire on that file too. `linux.yml` triggers on `linux/**`, and
/// `lint.yml`'s `rust` job filters on the same, so a contract test pointed at
/// `lambda/` or `react/` would otherwise report the drift it exists to catch on
/// the next unrelated push to `linux/` - long after the change that caused it
/// merged green.
///
/// Both workflows are checked, because both run `cargo xtask ci`: `lint.yml` on
/// the pull request, `linux.yml` on the push that merges it. A file covered by
/// only one of them is caught in only one of those places.
///
/// The registry in `tests/support/mod.rs` is what those tests read through, so
/// a new cross-tree test cannot be written without appearing here.
#[test]
fn every_file_the_tests_read_outside_the_workspace_triggers_both_gates() {
    assert!(
        !support::REPO_INPUTS.is_empty(),
        "the cross-tree registry is empty - has it moved?"
    );

    let push_gate = workflow();
    let pull_request_gate = lint_workflow();
    let filters = [
        ("linux.yml push filter", trigger_paths(&push_gate)),
        (
            "lint.yml rust filter",
            rust_filter_paths(&pull_request_gate),
        ),
    ];

    for file in support::REPO_INPUTS {
        assert!(
            repo_root().join(file).is_file(),
            "a test reads {file}, which does not exist"
        );
        for (name, patterns) in &filters {
            assert!(
                patterns.iter().any(|pattern| covers(pattern, file)),
                "a test reads {file} but the {name} does not cover it, so the \
                 check cannot run when that file changes. Add it there."
            );
        }
    }
}

/// The shell every step is written for. The runner falls back to `sh -e {0}`
/// where it is not told otherwise, and a container image whose `sh` is dash
/// then rejects `set -o pipefail` - which is exactly how `app-build` and
/// `app-test` failed on every run of this workflow until the default was
/// declared. Cheap to state, and the failure it prevents costs a whole run.
#[test]
fn the_workflow_runs_its_steps_under_bash() {
    let workflow = workflow();
    assert!(
        workflow.contains("defaults:\n  run:\n    shell: bash\n"),
        "linux.yml no longer declares `shell: bash` as a run default, so its \
         steps run under whatever the container calls `sh`"
    );
    for job in jobs(&workflow) {
        for line in job.body.lines() {
            let Some((_, shell)) = line.trim().split_once("shell: ") else {
                continue;
            };
            assert_eq!(
                shell.trim(),
                "bash",
                "job `{}` overrides the shell with `{shell}`; the steps are \
                 written in bash",
                job.name
            );
        }
    }
}

/// A file inside the workspace, read as text.
fn workspace_file(relative: &str) -> String {
    let path = repo_root().join("linux").join(relative);
    std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("reading {}: {e}", path.display()))
}

/// The version each workflow installs `cargo-deny` at, by job.
fn cargo_deny_versions(workflow: &str) -> Vec<(String, String)> {
    jobs(workflow)
        .into_iter()
        .filter_map(|job| {
            job.body
                .lines()
                .find_map(|line| line.trim().split_once(DENY_TOOL))
                .map(|(_, version)| (job.name.clone(), version.trim().to_owned()))
        })
        .collect()
}

/// The gate's `supply-chain` step runs `cargo deny`, which is a separate
/// binary: a job that runs the step without installing it fails with "not on
/// PATH" rather than reporting a licence result. Two workflows run that step -
/// `linux.yml` by name on a push, `lint.yml` as part of the whole gate on a
/// pull request - and neither can see what the other installs.
///
/// Both are asserted, and asserted to agree with the version `xtask/src/ci.rs`
/// and the README tell a developer to install. A pull request checked against
/// one version of the advisory rules and merged against another is a
/// difference nobody would think to look for, and a developer sent to a fifth
/// version reproduces neither.
#[test]
fn every_copy_of_the_cargo_deny_pin_agrees() {
    let push_gate = workflow();
    let pull_request_gate = lint_workflow();

    let running_the_step: Vec<String> = jobs(&push_gate)
        .into_iter()
        .filter(|job| job.steps().iter().any(|step| step == "supply-chain"))
        .map(|job| job.name)
        .collect();
    assert_eq!(
        running_the_step.len(),
        1,
        "expected exactly one job in linux.yml to run the supply-chain step, found {running_the_step:?}"
    );

    let whole_gate: Vec<String> = jobs(&pull_request_gate)
        .into_iter()
        .filter(|job| {
            job.body
                .lines()
                .any(|line| line.trim().ends_with("run: cargo xtask ci"))
        })
        .map(|job| job.name)
        .collect();
    assert_eq!(
        whole_gate.len(),
        1,
        "expected exactly one job in lint.yml to run the whole gate, found {whole_gate:?}"
    );

    let installed = |name: &str, workflow: &str, job: &str| -> String {
        let found = cargo_deny_versions(workflow);
        let (_, version) = found
            .iter()
            .find(|(installed_in, _)| installed_in == job)
            .unwrap_or_else(|| {
                panic!(
                    "job `{job}` in {name} runs the gate's supply-chain step but \
                     installs no cargo-deny, so it will fail with `not on PATH` \
                     instead of checking anything. Add a `{DENY_TOOL}<version>` step."
                )
            });
        version.clone()
    };

    let on_push = installed("linux.yml", &push_gate, &running_the_step[0]);
    let on_pull_request = installed("lint.yml", &pull_request_gate, &whole_gate[0]);
    assert_eq!(
        on_push, on_pull_request,
        "the two gates check the dependency graph with different cargo-deny versions"
    );
    assert!(
        on_push.split('.').count() == 3,
        "cargo-deny is pinned to `{on_push}`, which is not an exact x.y.z version"
    );

    for (file, found) in [
        ("xtask/src/ci.rs", pin_in_source()),
        ("README.md", pin_in_readme()),
    ] {
        assert_eq!(
            found, on_push,
            "{file} names cargo-deny {found}, the workflows install {on_push}. A \
             developer following that instruction checks the dependency graph \
             against different rules than the gate that has to pass."
        );
    }
}

/// The version `cargo xtask ci` prints when the binary is missing, taken from
/// the constant rather than from the message, so a reworded message still
/// points at one place.
fn pin_in_source() -> String {
    let source = workspace_file("xtask/src/ci.rs");
    let (_, after) = source
        .split_once(DENY_PIN_CONST)
        .expect("ci.rs declares CARGO_DENY_PIN");
    after
        .split_once('"')
        .expect("CARGO_DENY_PIN is a string literal")
        .0
        .to_owned()
}

/// The version the README tells a developer to install.
fn pin_in_readme() -> String {
    let readme = workspace_file("README.md");
    let (_, after) = readme.split_once(DENY_INSTALL).unwrap_or_else(|| {
        panic!(
            "linux/README.md does not spell the install as `{DENY_INSTALL}<version>`, \
             so nothing holds it to the version CI uses"
        )
    });
    after
        .split_whitespace()
        .next()
        .expect("the install line names a version")
        .trim_end_matches('`')
        .to_owned()
}

/// The `on:` block: everything above the first job.
fn triggers(workflow: &str) -> &str {
    workflow
        .split_once("\njobs:\n")
        .expect("the workflow declares jobs")
        .0
}

/// The quoted entries of the push `paths:` filter.
fn trigger_paths(workflow: &str) -> Vec<String> {
    triggers(workflow)
        .lines()
        .filter_map(|line| line.trim().strip_prefix("- '"))
        .filter_map(|rest| rest.strip_suffix('\''))
        .map(str::to_owned)
        .collect()
}

/// Whether a `paths:` entry matches `file`. Only the two forms the filter uses
/// are understood — an exact path, and a trailing `/**`. A third form fails
/// here rather than being silently read as "no match".
fn covers(pattern: &str, file: &str) -> bool {
    match pattern.strip_suffix("/**") {
        Some(prefix) => file.starts_with(&format!("{prefix}/")),
        None => {
            assert!(
                !pattern.contains('*'),
                "unhandled glob `{pattern}` in the paths filter - teach `covers` about it"
            );
            pattern == file
        }
    }
}

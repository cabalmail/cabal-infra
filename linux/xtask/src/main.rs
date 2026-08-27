//! `cargo xtask` — one deterministic spelling per build operation, shared by
//! humans and CI.
//!
//! Three of the five subcommands run today. The other two are declared rather
//! than omitted: the vocabulary is fixed here so the workflow, the README, and
//! the packaging notes can name the operation before the phase that implements
//! it lands, and so asking for one gets an answer about which work item owns
//! it instead of "unknown subcommand".

use std::path::{Path, PathBuf};
use std::process::ExitCode;

mod ci;
mod package;
mod process;
mod sync_vendored;

/// Every subcommand `cargo xtask` answers to.
const SUBCOMMANDS: &[Subcommand] = &[
    Subcommand {
        name: "sync-vendored",
        purpose: "materialize marked + turndown from react/admin/node_modules",
        status: Status::Live,
    },
    Subcommand {
        name: "ci",
        purpose: "fmt --check, clippy -D warnings, kit tests, app tests — in CI's order",
        status: Status::Live,
    },
    Subcommand {
        name: "package",
        purpose: "build a distribution package from the working tree and lint it",
        status: Status::Live,
    },
    Subcommand {
        name: "smoke",
        purpose: "install the built package, launch it headless, assert startup",
        status: Status::Pending("Phase 2, work item 3"),
    },
    Subcommand {
        name: "fixtures",
        purpose: "regenerate golden API fixtures from a live stage deployment",
        status: Status::Pending("Phase 2, work item 3"),
    },
];

struct Subcommand {
    name: &'static str,
    purpose: &'static str,
    status: Status,
}

enum Status {
    /// Implemented.
    Live,
    /// Declared, with the work item that implements it — which is what the
    /// error says, so the reader learns where to look rather than that they
    /// mistyped something.
    Pending(&'static str),
}

/// What a parsed command line asks for. Parsing is separated from doing so the
/// argument handling can be tested without running a build.
#[derive(Debug, PartialEq, Eq)]
enum Action {
    Help,
    /// The whole gate, or the single step named by `ci --step <name>`.
    Ci {
        only: Option<String>,
    },
    /// `ci --list`: the step names, one per line, for the workflow drift test.
    CiSteps,
    SyncVendored,
    /// `package <distro>`, for a distribution that is packaged today.
    Package {
        distro: String,
    },
    Pending {
        name: &'static str,
        work_item: &'static str,
    },
}

/// A failure to report. `usage` marks the ones where printing the subcommand
/// list is the useful next thing to show.
struct Failure {
    message: String,
    usage: bool,
}

impl Failure {
    fn usage(message: impl Into<String>) -> Self {
        Self {
            message: message.into(),
            usage: true,
        }
    }
}

impl From<String> for Failure {
    fn from(message: String) -> Self {
        Self {
            message,
            usage: false,
        }
    }
}

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match run(&args) {
        Ok(()) => ExitCode::SUCCESS,
        Err(failure) => {
            eprintln!("xtask: {}", failure.message);
            if failure.usage {
                eprintln!();
                eprint!("{}", usage());
            }
            ExitCode::FAILURE
        }
    }
}

fn run(args: &[String]) -> Result<(), Failure> {
    match parse(args)? {
        Action::Help => {
            print!("{}", usage());
            Ok(())
        }
        Action::Ci { only } => Ok(ci::run(&workspace_dir(), only.as_deref())?),
        Action::CiSteps => {
            for name in ci::step_names() {
                println!("{name}");
            }
            Ok(())
        }
        Action::SyncVendored => Ok(sync_vendored::run(&workspace_dir())?),
        Action::Package { distro } => match distro.as_str() {
            "arch" => Ok(package::arch(&workspace_dir())?),
            other => unreachable!("`{other}` parsed as packaged but has no builder"),
        },
        Action::Pending { name, work_item } => Err(Failure {
            message: format!(
                "`{name}` is declared but not implemented yet — it lands in {work_item}."
            ),
            usage: false,
        }),
    }
}

fn parse(args: &[String]) -> Result<Action, Failure> {
    let Some(name) = args.first() else {
        return Err(Failure::usage("no subcommand given"));
    };

    if matches!(name.as_str(), "-h" | "--help" | "help") {
        return Ok(Action::Help);
    }

    let Some(subcommand) = SUBCOMMANDS.iter().find(|known| known.name == name) else {
        return Err(Failure::usage(format!("unknown subcommand `{name}`")));
    };

    match subcommand.status {
        // A pending subcommand's arguments are not yet defined, so accepting
        // whatever was typed and reporting the work item is more useful than
        // ruling on an argument list nobody has designed.
        Status::Pending(work_item) => Ok(Action::Pending {
            name: subcommand.name,
            work_item,
        }),
        Status::Live => match subcommand.name {
            "ci" => parse_ci(&args[1..]),
            "package" => parse_package(&args[1..]),
            "sync-vendored" => {
                if let Some(extra) = args.get(1) {
                    return Err(Failure::usage(format!(
                        "`{name}` takes no arguments, got `{extra}`"
                    )));
                }
                Ok(Action::SyncVendored)
            }
            other => unreachable!("`{other}` is live but has no action"),
        },
    }
}

/// `ci` on its own runs the whole gate; `--step` and `--list` exist for the
/// workflow, which gives each step its own job so a failure names itself.
fn parse_ci(rest: &[String]) -> Result<Action, Failure> {
    let known = ci::step_names();
    match rest {
        [] => Ok(Action::Ci { only: None }),
        [flag] if flag == "--list" => Ok(Action::CiSteps),
        [flag] if flag == "--step" => Err(Failure::usage(format!(
            "`ci --step` needs a step name: {}",
            known.join(", ")
        ))),
        [flag, step] if flag == "--step" => {
            if known.contains(&step.as_str()) {
                Ok(Action::Ci {
                    only: Some(step.clone()),
                })
            } else {
                Err(Failure::usage(format!(
                    "no ci step named `{step}`. Steps: {}",
                    known.join(", ")
                )))
            }
        }
        [extra, ..] => Err(Failure::usage(format!(
            "`ci` takes no arguments, got `{extra}`"
        ))),
    }
}

/// `package` names its distribution. One that is not packaged yet answers with
/// the work item that will package it, the same way a pending subcommand does
/// — the reader learns where to look rather than that they mistyped something.
fn parse_package(rest: &[String]) -> Result<Action, Failure> {
    let known = package::distro_names();
    let [distro] = rest else {
        return Err(Failure::usage(format!(
            "`package` needs a distribution: {}",
            known.join(", ")
        )));
    };
    match package::pending_work_item(distro).map_err(Failure::usage)? {
        None => Ok(Action::Package {
            distro: distro.clone(),
        }),
        Some(work_item) => Err(Failure {
            message: format!(
                "`package {distro}` is declared but not implemented yet — it lands in \
                 {work_item}."
            ),
            usage: false,
        }),
    }
}

fn usage() -> String {
    let width = SUBCOMMANDS
        .iter()
        .map(|command| command.name.len())
        .max()
        .unwrap_or(0);

    let mut text = String::from("usage: cargo xtask <subcommand>\n\n");
    for command in SUBCOMMANDS {
        let name = command.name;
        let purpose = command.purpose;
        text.push_str(&format!("  {name:width$}  {purpose}\n"));
        if let Status::Pending(work_item) = command.status {
            text.push_str(&format!("  {:width$}  (not yet — {work_item})\n", ""));
        }
    }
    text.push_str(&format!(
        "\npackage takes a distribution: {}\n",
        package::distro_names().join(", ")
    ));
    text.push_str(&format!(
        "\nci runs every step; `ci --step <name>` runs one, which is how the\n\
         workflow gives each its own job. `ci --list` prints the names:\n  {}\n",
        ci::step_names().join(", ")
    ));
    text
}

/// The `linux/` workspace root. Taken from the manifest directory rather than
/// the working directory, so `cargo xtask` behaves the same from anywhere in
/// the tree.
fn workspace_dir() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("xtask lives inside the workspace root")
        .to_path_buf()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parse_args(args: &[&str]) -> Result<Action, Failure> {
        let owned: Vec<String> = args.iter().map(|arg| (*arg).to_owned()).collect();
        parse(&owned)
    }

    #[test]
    fn no_subcommand_asks_for_one() {
        let failure = parse_args(&[]).expect_err("nothing to do");
        assert!(failure.usage, "the subcommand list is the useful reply");
    }

    #[test]
    fn every_spelling_of_help_is_help() {
        for spelling in ["-h", "--help", "help"] {
            assert_eq!(parse_args(&[spelling]).ok(), Some(Action::Help));
        }
    }

    #[test]
    fn an_unknown_subcommand_is_a_usage_error() {
        let failure = parse_args(&["cli"]).expect_err("no such subcommand");
        assert!(failure.message.contains("`cli`"));
        assert!(failure.usage);
    }

    /// The point of declaring the three that have not landed: the reply names
    /// the work item, so the reader goes to the plan rather than to their
    /// shell history.
    #[test]
    fn a_pending_subcommand_names_the_work_item_that_implements_it() {
        for (name, work_item) in [
            ("smoke", "Phase 2, work item 3"),
            ("fixtures", "Phase 2, work item 3"),
        ] {
            assert_eq!(
                parse_args(&[name]).ok(),
                Some(Action::Pending { name, work_item })
            );
        }
    }

    #[test]
    fn packaging_takes_the_distribution_to_build() {
        assert_eq!(
            parse_args(&["package", "arch"]).ok(),
            Some(Action::Package {
                distro: "arch".to_owned()
            })
        );
    }

    /// Debian and RPM are Phase 8. Asking for one names the phase rather than
    /// reporting an unknown distribution, which would read as a typo.
    #[test]
    fn a_distribution_that_is_not_packaged_yet_names_the_work_item() {
        for distro in ["deb", "rpm"] {
            let failure = parse_args(&["package", distro]).expect_err("not packaged yet");
            assert!(
                failure.message.contains("Phase 8"),
                "`package {distro}` should say when it lands: {}",
                failure.message
            );
        }
    }

    #[test]
    fn packaging_without_a_distribution_lists_them() {
        let failure = parse_args(&["package"]).expect_err("nothing to build");
        for distro in package::distro_names() {
            assert!(
                failure.message.contains(distro),
                "the rejection should list `{distro}`: {}",
                failure.message
            );
        }
    }

    #[test]
    fn an_unknown_distribution_is_a_usage_error() {
        let failure = parse_args(&["package", "slackware"]).expect_err("no such distribution");
        assert!(failure.message.contains("slackware"));
        assert!(failure.usage);
    }

    #[test]
    fn a_live_subcommand_rejects_arguments_it_would_ignore() {
        for args in [["ci", "--fast"], ["sync-vendored", "--force"]] {
            let failure = parse_args(&args).expect_err("no such flag");
            assert!(
                failure.message.contains(args[1]),
                "the rejection should name what was typed: {}",
                failure.message
            );
        }
    }

    #[test]
    fn ci_on_its_own_runs_every_step() {
        assert_eq!(parse_args(&["ci"]).ok(), Some(Action::Ci { only: None }));
    }

    /// The workflow passes these; a renamed step has to fail here rather than
    /// as a mystery CI failure on a job that ran nothing.
    #[test]
    fn ci_selects_a_step_by_name() {
        for name in ci::step_names() {
            assert_eq!(
                parse_args(&["ci", "--step", name]).ok(),
                Some(Action::Ci {
                    only: Some(name.to_owned())
                })
            );
        }
    }

    #[test]
    fn an_unknown_ci_step_lists_the_real_ones() {
        let failure = parse_args(&["ci", "--step", "lint"]).expect_err("no such step");
        assert!(failure.message.contains("`lint`"));
        for name in ci::step_names() {
            assert!(
                failure.message.contains(name),
                "the rejection should list `{name}`: {}",
                failure.message
            );
        }
    }

    #[test]
    fn ci_step_without_a_name_says_so() {
        let failure = parse_args(&["ci", "--step"]).expect_err("nothing to select");
        assert!(failure.message.contains("needs a step name"));
    }

    #[test]
    fn ci_list_prints_the_step_names() {
        assert_eq!(parse_args(&["ci", "--list"]).ok(), Some(Action::CiSteps));
    }

    /// Either it runs on its own or it says what it needs. What must not
    /// happen is a live subcommand answering with "unknown subcommand".
    #[test]
    fn every_live_subcommand_either_runs_or_says_what_it_needs() {
        for command in SUBCOMMANDS {
            if !matches!(command.status, Status::Live) {
                continue;
            }
            match parse_args(&[command.name]) {
                Ok(_) => {}
                Err(failure) => assert!(
                    failure.usage && !failure.message.contains("unknown subcommand"),
                    "`{}` is live but reads as unknown: {}",
                    command.name,
                    failure.message
                ),
            }
        }
    }

    #[test]
    fn usage_lists_every_subcommand_and_flags_the_pending_ones() {
        let text = usage();
        for command in SUBCOMMANDS {
            assert!(
                text.contains(command.name) && text.contains(command.purpose),
                "`{}` is missing from the usage text",
                command.name
            );
            if let Status::Pending(work_item) = command.status {
                assert!(
                    text.contains(work_item),
                    "`{}` does not say when it lands",
                    command.name
                );
            }
        }
    }

    #[test]
    fn the_workspace_root_is_the_one_holding_the_members() {
        assert!(workspace_dir().join("Cargo.toml").is_file());
        assert!(workspace_dir().join("cabalmail-kit").is_dir());
    }
}

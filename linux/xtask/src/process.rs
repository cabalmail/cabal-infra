//! Running child processes the way a build tool should: echo the command
//! before it runs, let it write straight to the terminal, and turn a non-zero
//! exit into an error that repeats the command so the reader can run it again
//! by hand. A wrapper that swallows the invocation it chose is a wrapper people
//! stop trusting.

use std::io::Write;
use std::path::Path;
use std::process::Command;

/// One command in a sequence, with a short label for the log line and for the
/// failure message.
pub struct Step {
    pub label: &'static str,
    pub program: String,
    pub args: Vec<String>,
}

impl Step {
    pub fn new(
        label: &'static str,
        program: impl Into<String>,
        args: impl IntoIterator<Item = impl Into<String>>,
    ) -> Self {
        Self {
            label,
            program: program.into(),
            args: args.into_iter().map(Into::into).collect(),
        }
    }

    /// The step as it would be typed into a shell.
    pub fn command_line(&self) -> String {
        let mut line = quote(&self.program);
        for arg in &self.args {
            line.push(' ');
            line.push_str(&quote(arg));
        }
        line
    }
}

/// Runs `step` in `dir`, inheriting its output.
pub fn run(step: &Step, dir: &Path) -> Result<(), String> {
    // Our own line goes through the same fd as the child's output but not the
    // same buffer, so flush before handing over — otherwise a piped log shows
    // every command line bunched at the end, after the output it introduces.
    println!("[xtask] {}: {}", step.label, step.command_line());
    let _ = std::io::stdout().flush();

    let status = Command::new(&step.program)
        .args(&step.args)
        .current_dir(dir)
        .status()
        .map_err(|e| format!("could not run `{}`: {e}", step.program))?;

    if status.success() {
        return Ok(());
    }
    Err(format!(
        "{} failed ({status}). Run it again with:\n    cd {} && {}",
        step.label,
        dir.display(),
        step.command_line()
    ))
}

/// Single-quotes an argument if it contains anything a shell would act on, so
/// the echoed line can be pasted back verbatim.
fn quote(arg: &str) -> String {
    let safe = |c: char| c.is_ascii_alphanumeric() || "-_=+:,./@".contains(c);
    if !arg.is_empty() && arg.chars().all(safe) {
        return arg.to_owned();
    }
    format!("'{}'", arg.replace('\'', r"'\''"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_command_line_reads_back_as_it_was_typed() {
        let step = Step::new("clippy", "cargo", ["clippy", "--", "-D", "warnings"]);
        assert_eq!(step.command_line(), "cargo clippy -- -D warnings");
    }

    #[test]
    fn arguments_a_shell_would_act_on_are_quoted() {
        let step = Step::new("test", "cargo", ["test", "--", "--test-threads 1"]);
        assert_eq!(step.command_line(), "cargo test -- '--test-threads 1'");
    }

    #[test]
    fn a_missing_program_reports_the_program_rather_than_the_os_error_alone() {
        let step = Step::new("nonsense", "cabalmail-no-such-program", Vec::<&str>::new());
        let error = run(&step, Path::new(".")).expect_err("the program does not exist");
        assert!(
            error.contains("cabalmail-no-such-program"),
            "unhelpful error: {error}"
        );
    }
}

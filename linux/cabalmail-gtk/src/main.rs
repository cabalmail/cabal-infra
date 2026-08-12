//! Entry point for the Cabalmail Linux client.
//!
//! This is the command line and nothing else: it parses one invocation and
//! either answers it here — `--print-config`, `config set`, `config reset` —
//! or resolves the configuration and hands it to the application in
//! `cabalmail_gtk`. GTK is never given the command line; the flags are ours.

use std::process::ExitCode;

use cabalmail_kit::config::{self, Environment, Invocation, Key, Loaded, Settings, Value};

fn main() -> ExitCode {
    let arguments: Vec<String> = std::env::args().skip(1).collect();
    match run(&arguments) {
        Ok(code) => code,
        Err(message) => {
            eprintln!("cabalmail: {message}");
            ExitCode::from(2)
        }
    }
}

/// Dispatches one invocation, returning the message to print on failure.
fn run(arguments: &[String]) -> Result<ExitCode, String> {
    let invocation = Invocation::parse(arguments).map_err(|error| error.to_string())?;
    let environment = Environment::from_process();

    match invocation {
        Invocation::Help => {
            print!("{}", usage());
            Ok(ExitCode::SUCCESS)
        }
        Invocation::Version => {
            println!("cabalmail {}", env!("CARGO_PKG_VERSION"));
            Ok(ExitCode::SUCCESS)
        }
        Invocation::PrintConfig { overrides } => {
            let loaded = load(&environment, &overrides)?;
            print!("{}", config::render_report(&loaded));
            Ok(ExitCode::SUCCESS)
        }
        Invocation::Set { key, value } => write(&environment, key, &value),
        // Resetting writes the default explicitly rather than removing the
        // line: a missing key means "no local opinion", so deleting it would
        // leave the store's value untouched and the line would reappear on the
        // next rewrite.
        Invocation::Reset { key } => {
            let spec = key.spec();
            let value = spec
                .kind
                .parse(spec.default)
                .map_err(|detail| format!("the default for `{key}` is not valid: {detail}"))?;
            write(&environment, key, &value)
        }
        Invocation::Run { overrides } => {
            let loaded = load(&environment, &overrides)?;
            // Warnings are not fatal — a stale `CABALMAIL_*` variable in a
            // shell profile should be said out loud, not refuse to start the
            // client — so they go to stderr and the window still opens.
            for warning in &loaded.warnings {
                eprintln!("cabalmail: {warning}");
            }
            cabalmail_gtk::application::run(loaded.settings)
        }
    }
}

/// Loads configuration, rendering any failure as the message the user sees.
fn load(environment: &Environment, overrides: &[config::Override]) -> Result<Loaded, String> {
    config::load(environment, overrides).map_err(|error| error.to_string())
}

/// Writes one setting into the user's `config.toml`.
fn write(environment: &Environment, key: Key, value: &Value) -> Result<ExitCode, String> {
    // The current values are what a missing file is materialized from, so the
    // file the user ends up with reflects what the client was already doing.
    // Loading with no overrides keeps this run's flags out of it; the store's
    // persisted view keeps `CABALMAIL_*` out, which `load` has no way not to
    // apply.
    let settings = match config::load(environment, &[]) {
        Ok(loaded) => loaded.settings,
        Err(error) => return Err(error.to_string()),
    };
    let path = config::write_user_setting(environment, &settings, key, value)
        .map_err(|error| error.to_string())?;
    println!("{} = {} — written to {}", key, value, path.display());
    Ok(ExitCode::SUCCESS)
}

/// Usage text. The per-setting flags are deliberately not enumerated here —
/// there is one for every key in the schema, and the manual is where the list
/// belongs.
fn usage() -> String {
    let settings = Settings::defaults();
    let example = Key::DisposeAction;
    format!(
        "usage: cabalmail [--<setting> <value>]...\n\
         \x20      cabalmail --print-config\n\
         \x20      cabalmail config set <setting> <value>\n\
         \x20      cabalmail config reset <setting>\n\
         \n\
         options:\n\
         \x20 -h, --help           this message\n\
         \x20 -V, --version        print the version\n\
         \x20     --print-config   print every setting, its value, and where\n\
         \x20                      that value came from, then exit\n\
         \n\
         Every setting has a flag and an environment variable: `{}` is\n\
         `{}` or `{}`, currently `{}`. Flags and environment\n\
         variables apply for one run and are never written to your\n\
         configuration file; `cabalmail config set` writes it.\n\
         \n\
         See man 5 cabalmail for every setting.\n",
        example.name(),
        example.spec().flag(),
        example.spec().env_var(),
        settings.get(example),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The usage text is the only place a user is told the shape of the
    /// configuration CLI, so it has to name all four forms.
    #[test]
    fn usage_names_every_entry_point() {
        let usage = usage();
        for expected in [
            "--print-config",
            "config set",
            "config reset",
            "man 5 cabalmail",
        ] {
            assert!(usage.contains(expected), "usage is missing `{expected}`");
        }
    }

    #[test]
    fn an_unknown_option_fails_rather_than_starting() {
        let error = run(&["--nope".to_owned()]).expect_err("an unknown option is rejected");
        assert!(error.starts_with("unknown option"), "{error}");
    }

    #[test]
    fn help_and_version_succeed() {
        assert!(run(&["--help".to_owned()]).is_ok());
        assert!(run(&["--version".to_owned()]).is_ok());
    }

    /// `config reset` writes the built-in default, so every key's default has
    /// to survive the round trip through the parser it is written with.
    #[test]
    fn every_key_can_be_reset_to_a_value_the_schema_accepts() {
        for key in Key::ALL.iter().copied() {
            let spec = key.spec();
            let value = spec
                .kind
                .parse(spec.default)
                .unwrap_or_else(|e| panic!("the default for `{key}` is not valid: {e}"));
            assert_eq!(spec.kind.validate(&value), Ok(()), "{key}");
        }
    }
}

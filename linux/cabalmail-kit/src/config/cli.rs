//! Command-line parsing for the configuration surface.
//!
//! Every key in the schema gets a flag automatically — `dispose_action` is
//! `--dispose-action` — so the argument vocabulary cannot drift from the key
//! table. Flags are **transient local overrides**: they apply for the run, are
//! never written into `config.toml`, and are never pushed to the server.
//!
//! Living in the kit rather than in the application crate is deliberate: this
//! is the layer with no display server, so the whole surface is testable
//! without one, and `config set` works the same whether it was reached from a
//! terminal or from the Settings UI.

use super::error::{ConfigError, ConfigErrorKind};
use super::schema::{Key, Kind};
use super::settings::Source;
use super::value::Value;

/// A key/value pair supplied on the command line, with the flag it came from.
pub type Override = (Key, Value, Source);

/// What the user asked the binary to do.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Invocation {
    /// Start the client.
    Run { overrides: Vec<Override> },
    /// Print the effective configuration and exit.
    PrintConfig { overrides: Vec<Override> },
    /// Write one setting to the user's `config.toml` and exit.
    Set { key: Key, value: Value },
    /// Write one setting's built-in default to the user's `config.toml` and
    /// exit.
    ///
    /// Deleting the line does *not* do this: a missing key means "no local
    /// opinion", so the store keeps its value and the client re-adds the line
    /// on the next rewrite. Resetting has to say what the value now is.
    Reset { key: Key },
    /// Print usage and exit.
    Help,
    /// Print the version and exit.
    Version,
}

impl Invocation {
    /// Parses arguments, excluding the program name.
    ///
    /// # Errors
    ///
    /// If an option is unknown, missing its value, or carries a value its key
    /// does not accept.
    pub fn parse<I, S>(args: I) -> Result<Self, ConfigError>
    where
        I: IntoIterator<Item = S>,
        S: AsRef<str>,
    {
        let args: Vec<String> = args
            .into_iter()
            .map(|arg| arg.as_ref().to_owned())
            .collect();
        let mut overrides: Vec<Override> = Vec::new();
        let mut print_config = false;
        let mut index = 0;

        while index < args.len() {
            let arg = args[index].clone();
            index += 1;

            match arg.as_str() {
                "-h" | "--help" => return Ok(Self::Help),
                "-V" | "--version" => return Ok(Self::Version),
                "--print-config" => {
                    print_config = true;
                    continue;
                }
                "config" => {
                    let invocation = parse_config_command(&args[index..])?;
                    return Ok(invocation);
                }
                _ => {}
            }

            let (name, inline) = match arg.split_once('=') {
                Some((name, value)) => (name.to_owned(), Some(value.to_owned())),
                None => (arg.clone(), None),
            };

            let Some(key) = Key::from_flag(&name) else {
                return Err(ConfigError::new(ConfigErrorKind::UnknownFlag {
                    flag: name.clone(),
                    suggestion: nearest_flag(&name),
                }));
            };

            // A bare `--session-only` means true. Every other kind needs a
            // value, taken from `--key=value` or the next argument.
            let raw = match (inline, key.kind()) {
                (Some(inline), _) => inline,
                (None, Kind::Flag) => "true".to_owned(),
                (None, _) => {
                    let value = args.get(index).cloned().ok_or_else(|| {
                        ConfigError::new(ConfigErrorKind::MissingFlagValue { flag: name.clone() })
                    })?;
                    index += 1;
                    value
                }
            };

            let value = key.kind().parse(&raw).map_err(|detail| {
                ConfigError::new(ConfigErrorKind::InvalidFlag {
                    flag: name.clone(),
                    detail,
                })
            })?;
            overrides.retain(|(existing, _, _)| *existing != key);
            overrides.push((key, value, Source::Flag(name)));
        }

        Ok(if print_config {
            Self::PrintConfig { overrides }
        } else {
            Self::Run { overrides }
        })
    }
}

/// `config set <key> <value>` / `config reset <key>`.
fn parse_config_command(args: &[String]) -> Result<Invocation, ConfigError> {
    let unknown = |word: &str| {
        ConfigError::new(ConfigErrorKind::UnknownFlag {
            flag: format!("config {word}"),
            suggestion: Some("config set".to_owned()),
        })
    };

    let verb = args.first().ok_or_else(|| unknown(""))?;
    let name = args.get(1).ok_or_else(|| {
        ConfigError::new(ConfigErrorKind::MissingFlagValue {
            flag: format!("config {verb}"),
        })
    })?;
    let key = Key::from_name(name).ok_or_else(|| {
        ConfigError::new(ConfigErrorKind::UnknownKey {
            name: name.clone(),
            section: None,
            suggestion: super::error::nearest_key_name(name),
        })
    })?;

    match verb.as_str() {
        "set" => {
            let raw = args.get(2).ok_or_else(|| {
                ConfigError::new(ConfigErrorKind::MissingFlagValue {
                    flag: format!("config set {name}"),
                })
            })?;
            let value = key.kind().parse(raw).map_err(|detail| {
                ConfigError::new(ConfigErrorKind::InvalidValue { key, detail })
            })?;
            Ok(Invocation::Set { key, value })
        }
        "reset" => Ok(Invocation::Reset { key }),
        other => Err(unknown(other)),
    }
}

/// The declared flag closest to an unknown one.
fn nearest_flag(flag: &str) -> Option<String> {
    let name = flag.trim_start_matches('-').replace('-', "_");
    super::error::nearest_key_name(&name).map(|name| format!("--{}", name.replace('_', "-")))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn run(args: &[&str]) -> Invocation {
        Invocation::parse(args).expect("the arguments parse")
    }

    fn fail(args: &[&str]) -> ConfigError {
        Invocation::parse(args).expect_err("the arguments are rejected")
    }

    fn overrides(invocation: &Invocation) -> &[Override] {
        match invocation {
            Invocation::Run { overrides } | Invocation::PrintConfig { overrides } => overrides,
            other => panic!("{other:?} carries no overrides"),
        }
    }

    #[test]
    fn no_arguments_runs_the_client() {
        assert_eq!(run(&[]), Invocation::Run { overrides: vec![] });
    }

    #[test]
    fn every_key_has_a_working_flag() {
        for key in Key::ALL.iter().copied() {
            let spec = key.spec();
            let invocation = run(&[&format!("{}={}", spec.flag(), spec.default)]);
            let applied = overrides(&invocation);
            assert_eq!(applied.len(), 1, "{key}");
            assert_eq!(applied[0].0, key);
            assert_eq!(applied[0].2, Source::Flag(spec.flag()));
        }
    }

    #[test]
    fn a_value_may_be_attached_or_separate() {
        let attached = run(&["--dispose-action=trash"]);
        let separate = run(&["--dispose-action", "trash"]);
        assert_eq!(overrides(&attached)[0].1, Value::Text("trash".to_owned()));
        assert_eq!(overrides(&attached)[0].1, overrides(&separate)[0].1);
    }

    /// `--session-only` is the spelling the keyring failure path tells the user
    /// to run, and it has to work without an argument.
    #[test]
    fn a_bare_boolean_flag_means_true() {
        let invocation = run(&["--session-only"]);
        assert_eq!(
            overrides(&invocation)[0],
            (
                Key::SessionOnly,
                Value::Flag(true),
                Source::Flag("--session-only".to_owned())
            )
        );
        let invocation = run(&["--session-only=false"]);
        assert_eq!(overrides(&invocation)[0].1, Value::Flag(false));
    }

    #[test]
    fn the_last_spelling_of_a_flag_wins() {
        let invocation = run(&["--theme", "dark", "--theme", "light"]);
        assert_eq!(overrides(&invocation).len(), 1);
        assert_eq!(overrides(&invocation)[0].1, Value::Text("light".to_owned()));
    }

    #[test]
    fn print_config_still_collects_overrides() {
        let invocation = run(&["--print-config", "--log-level", "debug"]);
        assert!(matches!(invocation, Invocation::PrintConfig { .. }));
        assert_eq!(overrides(&invocation)[0].0, Key::LogLevel);
    }

    #[test]
    fn help_and_version_short_circuit() {
        assert_eq!(run(&["--help"]), Invocation::Help);
        assert_eq!(run(&["-h", "--nonsense"]), Invocation::Help);
        assert_eq!(run(&["--version"]), Invocation::Version);
    }

    #[test]
    fn config_set_and_reset_name_a_key() {
        assert_eq!(
            run(&["config", "set", "dispose_action", "trash"]),
            Invocation::Set {
                key: Key::DisposeAction,
                value: Value::Text("trash".to_owned()),
            }
        );
        assert_eq!(
            run(&["config", "reset", "dispose_action"]),
            Invocation::Reset {
                key: Key::DisposeAction
            }
        );
    }

    #[test]
    fn config_set_validates_the_value_it_is_given() {
        let error = fail(&["config", "set", "dispose_action", "incinerate"]);
        assert!(error.to_string().contains("`archive`"), "{error}");
        assert_eq!(error.key(), Some(Key::DisposeAction));
    }

    #[test]
    fn config_set_rejects_an_unknown_key() {
        let error = fail(&["config", "set", "mark_as_reed", "on_open"]);
        assert!(error.to_string().contains("mark_as_read"), "{error}");
    }

    #[test]
    fn a_missing_value_says_which_flag_wanted_one() {
        assert!(
            fail(&["--theme"])
                .to_string()
                .contains("--theme needs a value")
        );
        assert!(
            fail(&["config", "set", "theme"])
                .to_string()
                .contains("needs a value")
        );
    }

    #[test]
    fn an_unknown_flag_suggests_the_nearest_one() {
        let error = fail(&["--dispose-actions=trash"]);
        assert!(error.to_string().contains("--dispose-action"), "{error}");
        assert!(fail(&["--wat"]).to_string().starts_with("unknown option"));
    }

    #[test]
    fn a_bad_flag_value_is_rejected_the_same_way_a_file_value_is() {
        let error = fail(&["--cache-max-mb", "0"]);
        assert_eq!(
            error.to_string(),
            "invalid value for --cache-max-mb: must be between 1 and 1000000"
        );
    }
}

//! Configuration failures, with the position that makes them actionable.
//!
//! Malformed configuration is a hard, precise failure — file, line, column,
//! and the offending key — never a silent fall-back to defaults. A user who
//! typo'd a key needs to be told, not quietly ignored, and a client that
//! started with defaults instead would be indistinguishable from one that
//! ignored the file entirely.
//!
//! Deliberately not a case of [`CabalmailError`](crate::CabalmailError): that
//! taxonomy describes what a *request* did, is consumed by the outbox's
//! retry-or-surface branch, and has no notion of a file position. Configuration
//! is read before any request exists.

use std::fmt;
use std::path::{Path, PathBuf};

use super::schema::{Key, Scope};

/// A position in a configuration file, one-based, as an editor reports it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Location {
    /// The file the error is in.
    pub path: PathBuf,
    /// One-based line.
    pub line: usize,
    /// One-based column, counted in characters.
    pub column: usize,
}

impl Location {
    /// Resolves a byte offset into `text` to a line and column.
    ///
    /// Columns count characters rather than bytes so the number matches what
    /// an editor shows on a line with non-ASCII text in it.
    #[must_use]
    pub fn in_text(path: &Path, text: &str, offset: usize) -> Self {
        let offset = offset.min(text.len());
        let consumed = &text[..offset];
        let line = consumed.matches('\n').count() + 1;
        let column = consumed
            .rsplit_once('\n')
            .map_or(consumed, |(_, tail)| tail)
            .chars()
            .count()
            + 1;
        Self {
            path: path.to_path_buf(),
            line,
            column,
        }
    }
}

impl fmt::Display for Location {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}:{}:{}", self.path.display(), self.line, self.column)
    }
}

/// Everything that can go wrong reading configuration.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ConfigErrorKind {
    /// The file is not valid TOML.
    Syntax(String),
    /// The file could not be read or written.
    Io { path: PathBuf, detail: String },
    /// A key nobody declares. `section` is `None` at the document root.
    UnknownKey {
        name: String,
        section: Option<String>,
        /// The nearest declared name, when one is close enough to be a likely
        /// typo.
        suggestion: Option<&'static str>,
    },
    /// A declared key, in a section that disagrees with its sync scope.
    /// `found` is `None` at the document root.
    WrongSection {
        key: Key,
        found: Option<String>,
        expected: Scope,
    },
    /// A section nobody declares.
    UnknownSection { name: String },
    /// A key holding a table where a value belongs, or the reverse.
    NotAValue { name: String, section: String },
    /// A declared key with a value it does not accept.
    InvalidValue { key: Key, detail: String },
    /// A `CABALMAIL_*` variable with a value its key does not accept.
    InvalidEnv { var: String, detail: String },
    /// A flag with a value its key does not accept.
    InvalidFlag { flag: String, detail: String },
    /// A flag needing a value that did not get one.
    MissingFlagValue { flag: String },
    /// A flag nobody declares.
    UnknownFlag {
        flag: String,
        suggestion: Option<String>,
    },
    /// No user configuration directory could be resolved — no
    /// `XDG_CONFIG_HOME`, and no home directory to fall back to.
    NoConfigDirectory,
}

/// A configuration failure and, where there is one, where it happened.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ConfigError {
    /// Where in a file, for the failures that come from one.
    pub location: Option<Location>,
    /// What went wrong.
    pub kind: ConfigErrorKind,
}

impl ConfigError {
    /// A failure with no file position — a flag, an environment variable, or a
    /// path resolution.
    #[must_use]
    pub fn new(kind: ConfigErrorKind) -> Self {
        Self {
            location: None,
            kind,
        }
    }

    /// A failure at a position in a file.
    #[must_use]
    pub fn at(location: Location, kind: ConfigErrorKind) -> Self {
        Self {
            location: Some(location),
            kind,
        }
    }

    /// The key at fault, when one key is.
    #[must_use]
    pub fn key(&self) -> Option<Key> {
        match self.kind {
            ConfigErrorKind::WrongSection { key, .. }
            | ConfigErrorKind::InvalidValue { key, .. } => Some(key),
            _ => None,
        }
    }
}

/// `path:line:column: what went wrong` — the form every compiler and linter
/// uses, so an editor can jump to it.
impl fmt::Display for ConfigError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        if let Some(location) = &self.location {
            write!(f, "{location}: ")?;
        }
        match &self.kind {
            ConfigErrorKind::Syntax(detail) => write!(f, "{detail}"),
            ConfigErrorKind::Io { path, detail } => {
                write!(f, "couldn't read {}: {detail}", path.display())
            }
            ConfigErrorKind::UnknownKey {
                name,
                section,
                suggestion,
            } => {
                write!(f, "unknown setting `{name}` {}", section_phrase(section))?;
                if let Some(suggestion) = suggestion {
                    write!(f, " — did you mean `{suggestion}`?")?;
                }
                Ok(())
            }
            ConfigErrorKind::WrongSection {
                key,
                found,
                expected,
            } => write!(
                f,
                "`{key}` belongs in [{}], not {} — {}",
                expected.section(),
                match found {
                    Some(section) => format!("[{section}]"),
                    None => "the top level".to_owned(),
                },
                expected.summary()
            ),
            ConfigErrorKind::UnknownSection { name } => write!(
                f,
                "unknown section [{name}] — expected [preferences], [preferences.linux], or [local]"
            ),
            ConfigErrorKind::NotAValue { name, section } => write!(
                f,
                "`{name}` in [{section}] is a table, but it is a setting and needs a value"
            ),
            ConfigErrorKind::InvalidValue { key, detail } => {
                write!(f, "invalid value for `{key}`: {detail}")
            }
            ConfigErrorKind::InvalidEnv { var, detail } => {
                write!(f, "invalid value for {var}: {detail}")
            }
            ConfigErrorKind::InvalidFlag { flag, detail } => {
                write!(f, "invalid value for {flag}: {detail}")
            }
            ConfigErrorKind::MissingFlagValue { flag } => {
                write!(f, "{flag} needs a value")
            }
            ConfigErrorKind::UnknownFlag { flag, suggestion } => {
                write!(f, "unknown option {flag}")?;
                if let Some(suggestion) = suggestion {
                    write!(f, " — did you mean {suggestion}?")?;
                }
                Ok(())
            }
            ConfigErrorKind::NoConfigDirectory => f.write_str(
                "couldn't work out where configuration lives — set XDG_CONFIG_HOME or HOME",
            ),
        }
    }
}

impl std::error::Error for ConfigError {}

/// "in [preferences]", or "at the top level" for a key written outside every
/// section.
fn section_phrase(section: &Option<String>) -> String {
    match section {
        Some(section) => format!("in [{section}]"),
        None => "at the top level".to_owned(),
    }
}

/// The declared name closest to `name`, when one is close enough that a typo is
/// the likely explanation.
///
/// The bound scales with length so `mark_as_reed` suggests `mark_as_read`
/// while `foo` suggests nothing — a wrong suggestion is worse than none,
/// because it sends the user to rewrite a line that was never the problem.
#[must_use]
pub fn nearest_key_name(name: &str) -> Option<&'static str> {
    let budget = match name.chars().count() {
        0..=4 => 1,
        5..=9 => 2,
        _ => 3,
    };
    Key::ALL
        .iter()
        .map(|key| (edit_distance(name, key.name()), key.name()))
        .filter(|(distance, _)| *distance <= budget)
        .min_by_key(|(distance, _)| *distance)
        .map(|(_, name)| name)
}

/// Levenshtein distance, two rows at a time.
fn edit_distance(left: &str, right: &str) -> usize {
    let right: Vec<char> = right.chars().collect();
    let mut previous: Vec<usize> = (0..=right.len()).collect();
    let mut current = vec![0; right.len() + 1];

    for (i, left_char) in left.chars().enumerate() {
        current[0] = i + 1;
        for (j, right_char) in right.iter().enumerate() {
            let substitution = previous[j] + usize::from(left_char != *right_char);
            current[j + 1] = substitution.min(previous[j + 1] + 1).min(current[j] + 1);
        }
        std::mem::swap(&mut previous, &mut current);
    }
    previous[right.len()]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn positions_are_one_based_and_count_characters() {
        let text = "[preferences]\nsignature = \"héllo\"\nname = \"x\"\n";
        let offset = text.find("name").expect("the text contains `name`");
        let location = Location::in_text(Path::new("/tmp/config.toml"), text, offset);
        assert_eq!(location.line, 3);
        assert_eq!(location.column, 1);
        assert_eq!(location.to_string(), "/tmp/config.toml:3:1");

        let offset = text.find("\"x\"").expect("the text contains the value");
        let location = Location::in_text(Path::new("/tmp/config.toml"), text, offset);
        assert_eq!((location.line, location.column), (3, 8));
    }

    #[test]
    fn a_near_miss_suggests_the_key_it_missed() {
        assert_eq!(nearest_key_name("mark_as_reed"), Some("mark_as_read"));
        assert_eq!(nearest_key_name("signatures"), Some("signature"));
        assert_eq!(nearest_key_name("dispose_action"), Some("dispose_action"));
    }

    /// A confident wrong suggestion sends the user to rewrite a line that was
    /// never the problem, so distant names get none.
    #[test]
    fn a_distant_name_suggests_nothing() {
        assert_eq!(nearest_key_name("smtp_server"), None);
        assert_eq!(nearest_key_name("xyz"), None);
    }

    #[test]
    fn a_wrong_section_error_names_the_right_one() {
        let error = ConfigError::at(
            Location {
                path: PathBuf::from("/home/j/.config/cabalmail/config.toml"),
                line: 12,
                column: 1,
            },
            ConfigErrorKind::WrongSection {
                key: Key::CloseToTray,
                found: Some("preferences".to_owned()),
                expected: Scope::Linux,
            },
        );
        let rendered = error.to_string();
        assert!(rendered.starts_with("/home/j/.config/cabalmail/config.toml:12:1: "));
        assert!(rendered.contains("`close_to_tray` belongs in [preferences.linux]"));
        assert!(rendered.contains("not [preferences]"));
    }

    #[test]
    fn an_unknown_key_error_carries_the_suggestion() {
        let error = ConfigError::new(ConfigErrorKind::UnknownKey {
            name: "mark_as_reed".to_owned(),
            section: Some("preferences".to_owned()),
            suggestion: nearest_key_name("mark_as_reed"),
        });
        assert_eq!(
            error.to_string(),
            "unknown setting `mark_as_reed` in [preferences] — did you mean `mark_as_read`?"
        );

        let error = ConfigError::new(ConfigErrorKind::UnknownKey {
            name: "smtp_server".to_owned(),
            section: None,
            suggestion: None,
        });
        assert_eq!(
            error.to_string(),
            "unknown setting `smtp_server` at the top level"
        );
    }
}

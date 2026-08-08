//! The resolved configuration store: one value per key, each carrying where it
//! came from.
//!
//! Provenance is not a debugging afterthought. `--print-config` reports it,
//! Phase 6's Settings UI shows it, and layering depends on it — a value only
//! replaces one from a lower-precedence source, which is what lets the server
//! pull land asynchronously after startup without stepping on the file the
//! user edited.

use std::path::PathBuf;

use super::schema::{Key, Scope};
use super::value::Value;

/// Where a value came from. Ordered lowest precedence first.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Source {
    /// The built-in default from the key table.
    Default,
    /// The server's synced preferences.
    Server,
    /// A file found under `$XDG_CONFIG_DIRS` — the distro or site defaults
    /// drop point.
    SystemFile(PathBuf),
    /// The user's own `$XDG_CONFIG_HOME/cabalmail/config.toml`.
    UserFile(PathBuf),
    /// A `CABALMAIL_*` environment variable.
    Env(String),
    /// A command-line flag.
    Flag(String),
}

impl Source {
    /// Precedence, highest wins. Command-line flags beat environment
    /// variables, which beat the user's file, which beats the system files,
    /// which beat the server, which beats the defaults.
    #[must_use]
    pub fn rank(&self) -> u8 {
        match self {
            Self::Default => 0,
            Self::Server => 1,
            Self::SystemFile(_) => 2,
            Self::UserFile(_) => 3,
            Self::Env(_) => 4,
            Self::Flag(_) => 5,
        }
    }

    /// The short name shown in `--print-config`'s provenance column.
    #[must_use]
    pub fn label(&self) -> &'static str {
        match self {
            Self::Default => "default",
            Self::Server => "server",
            Self::SystemFile(_) => "system file",
            Self::UserFile(_) => "user file",
            Self::Env(_) => "env",
            Self::Flag(_) => "flag",
        }
    }

    /// The exact origin — which file, which variable, which flag — for the
    /// sources that have one.
    #[must_use]
    pub fn origin(&self) -> Option<String> {
        match self {
            Self::Default | Self::Server => None,
            Self::SystemFile(path) | Self::UserFile(path) => Some(path.display().to_string()),
            Self::Env(name) | Self::Flag(name) => Some(name.clone()),
        }
    }

    /// Whether a value from this source is a transient local override —
    /// applied for this run, never written to the file, never pushed to the
    /// server.
    #[must_use]
    pub fn is_transient(&self) -> bool {
        matches!(self, Self::Env(_) | Self::Flag(_))
    }
}

/// One key's current value and where it came from.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Resolved {
    /// The value in force.
    pub value: Value,
    /// Where it came from.
    pub source: Source,
}

/// Every key's resolved value.
///
/// Total by construction: every key has an entry from the moment the store is
/// built, because the defaults populate it. There is no "unset" state for a
/// caller to handle, which is what keeps later phases from each inventing
/// their own fallback for a missing setting.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Settings {
    /// Indexed by `key as usize`; see the discriminant test in `schema`.
    values: Vec<Resolved>,
}

impl Settings {
    /// The built-in defaults, every key sourced [`Source::Default`].
    ///
    /// # Panics
    ///
    /// If a key's declared default does not validate against its own kind,
    /// which is a bug in the key table and is covered by a test.
    #[must_use]
    pub fn defaults() -> Self {
        let values = Key::ALL
            .iter()
            .map(|key| {
                let spec = key.spec();
                let value = spec
                    .kind
                    .parse(spec.default)
                    .unwrap_or_else(|e| panic!("default for `{key}` is not valid: {e}"));
                Resolved {
                    value,
                    source: Source::Default,
                }
            })
            .collect();
        Self { values }
    }

    /// This key's resolved value and provenance.
    #[must_use]
    pub fn resolved(&self, key: Key) -> &Resolved {
        &self.values[key as usize]
    }

    /// This key's value.
    #[must_use]
    pub fn get(&self, key: Key) -> &Value {
        &self.resolved(key).value
    }

    /// Where this key's value came from.
    #[must_use]
    pub fn source(&self, key: Key) -> &Source {
        &self.resolved(key).source
    }

    /// Applies a value if `source` outranks the one already in force.
    ///
    /// Equal ranks do not replace, so the first file found in `$XDG_CONFIG_DIRS`
    /// wins over later ones — the order the spec gives that list.
    ///
    /// Returns whether the value was taken.
    pub fn apply(&mut self, key: Key, value: Value, source: Source) -> bool {
        let slot = &mut self.values[key as usize];
        if source.rank() > slot.source.rank() {
            *slot = Resolved { value, source };
            true
        } else {
            false
        }
    }

    /// Overwrites a value regardless of precedence.
    ///
    /// For the writers that own the store outright — the Settings UI and
    /// `config set`, which write the file and then reflect the change.
    pub fn set(&mut self, key: Key, value: Value, source: Source) {
        self.values[key as usize] = Resolved { value, source };
    }

    /// Every key in declaration order, with its resolved value.
    pub fn iter(&self) -> impl Iterator<Item = (Key, &Resolved)> {
        Key::ALL.iter().copied().zip(self.values.iter())
    }

    /// Every key in one scope, in declaration order.
    pub fn iter_scope(&self, scope: Scope) -> impl Iterator<Item = (Key, &Resolved)> {
        self.iter().filter(move |(key, _)| key.scope() == scope)
    }

    /// The text value of a key.
    ///
    /// # Panics
    ///
    /// If the key is not text-shaped — a mismatch between a call site and the
    /// key table, the same class of bug as indexing past the end of a slice.
    #[must_use]
    pub fn text(&self, key: Key) -> &str {
        self.get(key)
            .as_text()
            .unwrap_or_else(|| panic!("`{key}` is not a text setting"))
    }

    /// The boolean value of a key.
    ///
    /// # Panics
    ///
    /// If the key is not a flag.
    #[must_use]
    pub fn flag(&self, key: Key) -> bool {
        self.get(key)
            .as_flag()
            .unwrap_or_else(|| panic!("`{key}` is not a flag setting"))
    }

    /// The numeric value of a key.
    ///
    /// # Panics
    ///
    /// If the key is not numeric.
    #[must_use]
    pub fn number(&self, key: Key) -> i64 {
        self.get(key)
            .as_number()
            .unwrap_or_else(|| panic!("`{key}` is not a numeric setting"))
    }

    /// The token list of a key.
    ///
    /// # Panics
    ///
    /// If the key is not a token list.
    #[must_use]
    pub fn list(&self, key: Key) -> &[String] {
        self.get(key)
            .as_list()
            .unwrap_or_else(|| panic!("`{key}` is not a list setting"))
    }

    /// Applies a pull of the server's synced preferences.
    ///
    /// Values arrive untyped (the wire carries strings) and are matched by
    /// their [`Wire`](super::schema::Wire) name rather than their file name, so
    /// a platform-scoped key is recognised under its `linux_` prefix. A value
    /// the client cannot make sense of is ignored rather than fatal — an older
    /// client must not refuse to start because a newer one wrote a key it does
    /// not know, and the server is not a surface where the user can fix a typo.
    ///
    /// Returns the wire names that were ignored, for the debug log.
    pub fn apply_server<'a, I>(&mut self, pairs: I) -> Vec<String>
    where
        I: IntoIterator<Item = (&'a str, &'a str)>,
    {
        let mut ignored = Vec::new();
        for (name, raw) in pairs {
            let Some(key) = Key::ALL
                .iter()
                .copied()
                .find(|key| key.spec().wire.name() == Some(name))
            else {
                ignored.push(name.to_owned());
                continue;
            };
            match key.spec().kind.parse(raw) {
                Ok(value) => {
                    self.apply(key, value, Source::Server);
                }
                Err(_) => ignored.push(name.to_owned()),
            }
        }
        ignored
    }
}

impl Default for Settings {
    fn default() -> Self {
        Self::defaults()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::Path;

    fn user_file() -> Source {
        Source::UserFile(PathBuf::from("/home/j/.config/cabalmail/config.toml"))
    }

    #[test]
    fn defaults_cover_every_key_and_report_themselves_as_default() {
        let settings = Settings::defaults();
        assert_eq!(settings.iter().count(), Key::ALL.len());
        for (key, resolved) in settings.iter() {
            assert_eq!(resolved.source, Source::Default, "{key}");
        }
        assert_eq!(settings.text(Key::DisposeAction), "archive");
        assert_eq!(settings.number(Key::CacheMaxMb), 200);
        assert!(!settings.flag(Key::CloseToTray));
        assert_eq!(settings.list(Key::NotificationActions).len(), 3);
    }

    /// The whole precedence table, applied out of order to prove ranks decide
    /// rather than call order.
    #[test]
    fn higher_precedence_wins_regardless_of_application_order() {
        let mut settings = Settings::defaults();

        assert!(settings.apply(
            Key::DisposeAction,
            Value::Text("trash".to_owned()),
            Source::Flag("--dispose-action".to_owned())
        ));
        for lower in [
            Source::Env("CABALMAIL_DISPOSE_ACTION".to_owned()),
            user_file(),
            Source::SystemFile(PathBuf::from("/etc/xdg/cabalmail/config.toml")),
            Source::Server,
        ] {
            assert!(
                !settings.apply(Key::DisposeAction, Value::Text("archive".to_owned()), lower),
                "a lower-precedence source overwrote a flag"
            );
        }
        assert_eq!(settings.text(Key::DisposeAction), "trash");
    }

    /// `$XDG_CONFIG_DIRS` is ordered: the first entry that sets a key wins.
    #[test]
    fn the_first_system_file_wins_over_later_ones() {
        let mut settings = Settings::defaults();
        let first = Source::SystemFile(PathBuf::from("/etc/xdg/cabalmail/config.toml"));
        let second = Source::SystemFile(PathBuf::from("/usr/etc/xdg/cabalmail/config.toml"));

        assert!(settings.apply(Key::Theme, Value::Text("dark".to_owned()), first.clone()));
        assert!(!settings.apply(Key::Theme, Value::Text("light".to_owned()), second));
        assert_eq!(settings.text(Key::Theme), "dark");
        assert_eq!(settings.source(Key::Theme), &first);
    }

    /// The server pull lands after startup, so it has to be applicable to an
    /// already-layered store without disturbing what the user set locally.
    #[test]
    fn a_server_pull_fills_defaults_and_leaves_local_edits_alone() {
        let mut settings = Settings::defaults();
        settings.apply(Key::Theme, Value::Text("light".to_owned()), user_file());

        let ignored = settings.apply_server([
            ("theme", "dark"),
            ("dispose_action", "trash"),
            ("signature", "-- \nsent"),
        ]);

        assert!(ignored.is_empty());
        assert_eq!(settings.text(Key::Theme), "light");
        assert_eq!(settings.text(Key::DisposeAction), "trash");
        assert_eq!(settings.source(Key::DisposeAction), &Source::Server);
    }

    /// A key the Apple client owns, a key a future client invents, and a value
    /// this client cannot parse all have to be survivable — the alternative is
    /// a client that will not start because another platform wrote a setting.
    #[test]
    fn unknown_and_unparseable_server_values_are_ignored_not_fatal() {
        let mut settings = Settings::defaults();
        let ignored = settings.apply_server([
            ("crash_reporting_enabled", "1"),
            ("someday_key", "x"),
            ("dispose_action", "incinerate"),
        ]);
        assert_eq!(
            ignored,
            vec!["crash_reporting_enabled", "someday_key", "dispose_action"]
        );
        assert_eq!(settings.text(Key::DisposeAction), "archive");
    }

    /// Platform-scoped keys are recognised by their prefixed wire name, which
    /// is the only form they exist in on the server.
    #[test]
    fn platform_scoped_keys_arrive_under_their_prefix() {
        let mut settings = Settings::defaults();
        let ignored = settings.apply_server([("linux_close_to_tray", "true")]);
        assert!(ignored.is_empty());
        assert!(settings.flag(Key::CloseToTray));

        // The unprefixed spelling is not a thing on the wire.
        let mut settings = Settings::defaults();
        assert_eq!(
            settings.apply_server([("close_to_tray", "true")]),
            vec!["close_to_tray"]
        );
    }

    #[test]
    fn provenance_reports_its_origin() {
        let source = user_file();
        assert_eq!(source.label(), "user file");
        assert_eq!(
            source.origin().as_deref(),
            Some("/home/j/.config/cabalmail/config.toml")
        );
        assert!(!source.is_transient());

        let source = Source::Env("CABALMAIL_LOG_LEVEL".to_owned());
        assert_eq!(source.label(), "env");
        assert_eq!(source.origin().as_deref(), Some("CABALMAIL_LOG_LEVEL"));
        assert!(source.is_transient());

        assert_eq!(Source::Default.origin(), None);
    }

    #[test]
    fn scope_iteration_covers_the_table_exactly_once() {
        let settings = Settings::defaults();
        let counted: usize = Scope::ALL
            .iter()
            .map(|scope| settings.iter_scope(*scope).count())
            .sum();
        assert_eq!(counted, Key::ALL.len());
    }

    #[test]
    fn set_overwrites_regardless_of_precedence() {
        let mut settings = Settings::defaults();
        settings.apply(
            Key::Theme,
            Value::Text("dark".to_owned()),
            Source::Flag("--theme".to_owned()),
        );
        settings.set(
            Key::Theme,
            Value::Text("light".to_owned()),
            Source::UserFile(Path::new("/tmp/config.toml").to_path_buf()),
        );
        assert_eq!(settings.text(Key::Theme), "light");
    }
}

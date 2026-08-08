//! Layered user configuration: the schema, the store, and the `config.toml`
//! reader and writer.
//!
//! Lands in Phase 1, work item 3 — before anything reads a setting, so that
//! precedence and provenance are never retrofitted. The propagation machinery
//! that points three writers at this store (file watching, debounce, server
//! push and pull) is Phase 6; what is here is the store, the schema, and the
//! file I/O it depends on, deliberately built and tested first.
//!
//! Not to be confused with the *deployment descriptor* (`Deployment`, Phase 3),
//! which is fetched from `https://{control_domain}/config.json` and owned by
//! the deployment rather than the user. This module is the user's file.
//!
//! # Precedence, highest wins
//!
//! 1. Command-line flags
//! 2. Environment variables (`CABALMAIL_*`)
//! 3. `$XDG_CONFIG_HOME/cabalmail/config.toml`
//! 4. Each entry of `$XDG_CONFIG_DIRS`, in order
//! 5. Server-synced preferences
//! 6. Built-in defaults
//!
//! Flags and environment variables are transient: they apply for the run, are
//! never written to the file, and are never pushed. Everything else
//! participates in propagation.
//!
//! The file is **not** an override layer that suppresses sync. It is a peer
//! editor — a second input device onto the same store the Settings UI writes
//! to, and a materialized view of that store's synced section. Editing a key
//! in `$EDITOR` behaves exactly as if it had been changed in Settings.

pub mod cli;
pub mod docs;
pub mod env;
pub mod error;
pub mod file;
pub mod schema;
pub mod settings;
pub mod value;

use std::path::PathBuf;

pub use cli::{Invocation, Override};
pub use env::Environment;
pub use error::{ConfigError, ConfigErrorKind, Location};
pub use schema::{Key, KeySpec, Kind, Reload, Scope, Wire};
pub use settings::{Resolved, Settings, Source};
pub use value::Value;

/// A resolved configuration, and what went into it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Loaded {
    /// Every key's value and provenance.
    pub settings: Settings,
    /// Where the user's file is, whether or not it exists yet. `None` when no
    /// configuration directory could be resolved at all.
    pub user_path: Option<PathBuf>,
    /// The files that were actually read, in the order they were applied.
    pub files: Vec<PathBuf>,
    /// Non-fatal complaints — an unrecognised `CABALMAIL_*` variable, say.
    ///
    /// Warnings rather than errors, because the environment is not a surface
    /// the user is necessarily editing: a stale variable in a shell profile
    /// should be reported, not refuse to start the client. A *file* is
    /// different, and a bad key there is fatal.
    pub warnings: Vec<String>,
}

/// Resolves configuration from every layer.
///
/// `overrides` come from [`Invocation::parse`]; the environment is captured in
/// [`Environment`] so a caller — or a test — decides what it sees.
///
/// # Errors
///
/// If any file that exists is malformed, or an environment variable carries a
/// value its key does not accept. Nothing falls back to defaults on the way
/// past: a user who typo'd a setting is told, with the file, line, column, and
/// the offending key.
pub fn load(environment: &Environment, overrides: &[Override]) -> Result<Loaded, ConfigError> {
    let mut settings = Settings::defaults();
    let mut files = Vec::new();
    let mut warnings = Vec::new();

    // `$XDG_CONFIG_DIRS` is ordered, and `Settings::apply` keeps the first
    // source at a given rank, so applying them in order gives the earlier
    // directory precedence.
    for path in environment.system_config_files() {
        if let Some(text) = file::read(&path)? {
            for (key, value) in file::parse(&path, &text)? {
                settings.apply(key, value, Source::SystemFile(path.clone()));
            }
            files.push(path);
        }
    }

    let user_path = environment.user_config_file();
    if let Some(path) = &user_path
        && let Some(text) = file::read(path)?
    {
        for (key, value) in file::parse(path, &text)? {
            settings.apply(key, value, Source::UserFile(path.clone()));
        }
        files.push(path.clone());
    }

    for (var, raw) in environment.cabalmail_vars() {
        let Some(key) = Key::from_env_var(var) else {
            warnings.push(format!("ignoring unknown environment variable {var}"));
            continue;
        };
        let value = key.kind().parse(raw).map_err(|detail| {
            ConfigError::new(ConfigErrorKind::InvalidEnv {
                var: var.to_owned(),
                detail,
            })
        })?;
        settings.apply(key, value, Source::Env(var.to_owned()));
    }

    for (key, value, source) in overrides {
        settings.apply(*key, value.clone(), source.clone());
    }

    Ok(Loaded {
        settings,
        user_path,
        files,
        warnings,
    })
}

/// Writes one setting into the user's `config.toml`.
///
/// The file is created — in full, every key at its current value — if it does
/// not exist yet.
///
/// # Errors
///
/// If no configuration directory can be resolved, or the file cannot be read
/// or written.
pub fn write_user_setting(
    environment: &Environment,
    settings: &Settings,
    key: Key,
    value: &Value,
) -> Result<PathBuf, ConfigError> {
    let path = environment
        .user_config_file()
        .ok_or_else(|| ConfigError::new(ConfigErrorKind::NoConfigDirectory))?;
    file::set_key(&path, settings, key, value)?;
    Ok(path)
}

/// The `--print-config` report: every key, its effective value, and where that
/// value came from.
///
/// A configuration with three writers that cannot explain itself is a support
/// burden. This pays for itself the first time someone says a setting will not
/// stick.
#[must_use]
pub fn render_report(loaded: &Loaded) -> String {
    let settings = &loaded.settings;
    let name_width = Key::ALL
        .iter()
        .map(|key| key.name().len())
        .max()
        .unwrap_or_default()
        + 2;
    let value_width = Key::ALL
        .iter()
        .map(|key| settings.get(*key).to_toml().chars().count())
        .max()
        .unwrap_or_default()
        .min(40)
        + 2;

    let mut out = String::new();
    out.push_str(
        "# Effective configuration. Precedence, highest first: flag, env,\n\
         # user file, system file, server, default.\n",
    );
    match &loaded.user_path {
        Some(path) if loaded.files.contains(path) => {
            out.push_str(&format!("# User file: {}\n", path.display()));
        }
        Some(path) => out.push_str(&format!("# User file: {} (not present)\n", path.display())),
        None => out.push_str("# User file: none — no configuration directory could be resolved\n"),
    }

    let mut restart_marked = false;
    for scope in Scope::ALL.iter().copied() {
        out.push_str(&format!("\n[{}]\n", scope.section()));
        for (key, resolved) in settings.iter_scope(scope) {
            let restart = key.spec().reload == Reload::Restart;
            restart_marked |= restart;
            let name = format!("{}{}", key.name(), if restart { " *" } else { "" });
            let origin = resolved
                .source
                .origin()
                .map(|origin| format!("  {origin}"))
                .unwrap_or_default();
            out.push_str(&format!(
                "  {name:name_width$}{:value_width$}{}{origin}\n",
                resolved.value.to_toml(),
                resolved.source.label(),
            ));
        }
    }

    if restart_marked {
        out.push_str("\n* takes effect on the next start\n");
    }
    for warning in &loaded.warnings {
        out.push_str(&format!("\nwarning: {warning}\n"));
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::Path;

    /// Builds an environment pointing at `directory` for the user's config and
    /// `system` (if any) for the system list, with nothing else set.
    fn environment(directory: &Path, system: Option<&Path>) -> Environment {
        let mut pairs = vec![(
            "XDG_CONFIG_HOME".to_owned(),
            directory.display().to_string(),
        )];
        if let Some(system) = system {
            pairs.push(("XDG_CONFIG_DIRS".to_owned(), system.display().to_string()));
        } else {
            // An absolute path that will not exist, so the default `/etc/xdg`
            // never leaks a real machine's file into a test.
            pairs.push((
                "XDG_CONFIG_DIRS".to_owned(),
                directory.join("no-such-system-dir").display().to_string(),
            ));
        }
        Environment::from_pairs(pairs)
    }

    fn write_config(root: &Path, contents: &str) -> PathBuf {
        let path = root.join("cabalmail").join("config.toml");
        std::fs::create_dir_all(path.parent().expect("the file has a parent"))
            .expect("the directory is created");
        std::fs::write(&path, contents).expect("the fixture writes");
        path
    }

    /// On a clean system every key reports itself as a default — the first of
    /// the phase's verification criteria, and the baseline the rest build on.
    #[test]
    fn a_clean_system_reports_every_key_as_default() {
        let home = tempfile::tempdir().expect("a temp directory");
        let loaded = load(&environment(home.path(), None), &[]).expect("the load succeeds");

        assert!(loaded.files.is_empty());
        assert!(loaded.warnings.is_empty());
        for (key, resolved) in loaded.settings.iter() {
            assert_eq!(resolved.source, Source::Default, "{key}");
        }
        assert_eq!(
            loaded.user_path,
            Some(home.path().join("cabalmail").join("config.toml"))
        );
    }

    /// One key in the user's file moves that key's provenance and nothing
    /// else's.
    #[test]
    fn a_user_file_claims_the_keys_it_sets_and_no_others() {
        let home = tempfile::tempdir().expect("a temp directory");
        let path = write_config(home.path(), "[preferences]\ndispose_action = \"trash\"\n");

        let loaded = load(&environment(home.path(), None), &[]).expect("the load succeeds");

        assert_eq!(loaded.files, vec![path.clone()]);
        assert_eq!(loaded.settings.text(Key::DisposeAction), "trash");
        assert_eq!(
            loaded.settings.source(Key::DisposeAction),
            &Source::UserFile(path)
        );
        assert_eq!(loaded.settings.source(Key::Theme), &Source::Default);
    }

    /// The full stack, one key at a time: each layer takes the key from the
    /// one below it, and leaves the rest alone.
    #[test]
    fn each_layer_overrides_the_one_below_it() {
        let home = tempfile::tempdir().expect("a temp directory");
        let system_root = tempfile::tempdir().expect("a temp directory");
        write_config(system_root.path(), "[preferences]\ntheme = \"light\"\n");
        write_config(home.path(), "[preferences]\ntheme = \"dark\"\n");

        // System file only.
        let system_env = Environment::from_pairs([
            (
                "XDG_CONFIG_HOME".to_owned(),
                home.path().join("empty").display().to_string(),
            ),
            (
                "XDG_CONFIG_DIRS".to_owned(),
                system_root.path().display().to_string(),
            ),
        ]);
        let loaded = load(&system_env, &[]).expect("the load succeeds");
        assert_eq!(loaded.settings.text(Key::Theme), "light");
        assert_eq!(loaded.settings.source(Key::Theme).label(), "system file");

        // The user's file beats it.
        let mut pairs = vec![
            (
                "XDG_CONFIG_HOME".to_owned(),
                home.path().display().to_string(),
            ),
            (
                "XDG_CONFIG_DIRS".to_owned(),
                system_root.path().display().to_string(),
            ),
        ];
        let loaded = load(&Environment::from_pairs(pairs.clone()), &[]).expect("the load succeeds");
        assert_eq!(loaded.settings.text(Key::Theme), "dark");
        assert_eq!(loaded.settings.source(Key::Theme).label(), "user file");

        // The environment beats the file.
        pairs.push(("CABALMAIL_THEME".to_owned(), "system".to_owned()));
        let loaded = load(&Environment::from_pairs(pairs.clone()), &[]).expect("the load succeeds");
        assert_eq!(loaded.settings.text(Key::Theme), "system");
        assert_eq!(
            loaded.settings.source(Key::Theme),
            &Source::Env("CABALMAIL_THEME".to_owned())
        );

        // A flag beats everything.
        let overrides = vec![(
            Key::Theme,
            Value::Text("light".to_owned()),
            Source::Flag("--theme".to_owned()),
        )];
        let loaded = load(&Environment::from_pairs(pairs), &overrides).expect("the load succeeds");
        assert_eq!(loaded.settings.text(Key::Theme), "light");
        assert_eq!(loaded.settings.source(Key::Theme).label(), "flag");
    }

    /// No hard-coded `~/.config` anywhere: pointing `XDG_CONFIG_HOME` at a
    /// temp directory relocates the whole lookup.
    #[test]
    fn the_lookup_follows_xdg_config_home() {
        let first = tempfile::tempdir().expect("a temp directory");
        let second = tempfile::tempdir().expect("a temp directory");
        write_config(first.path(), "[local]\nlog_level = \"debug\"\n");
        write_config(second.path(), "[local]\nlog_level = \"trace\"\n");

        let loaded = load(&environment(first.path(), None), &[]).expect("the load succeeds");
        assert_eq!(loaded.settings.text(Key::LogLevel), "debug");
        let loaded = load(&environment(second.path(), None), &[]).expect("the load succeeds");
        assert_eq!(loaded.settings.text(Key::LogLevel), "trace");
    }

    #[test]
    fn a_malformed_user_file_is_fatal_and_not_defaulted() {
        let home = tempfile::tempdir().expect("a temp directory");
        let path = write_config(home.path(), "[preferences]\ndispose_actoin = \"trash\"\n");

        let error = load(&environment(home.path(), None), &[]).expect_err("the load fails");

        let location = error
            .location
            .clone()
            .expect("the error carries a position");
        assert_eq!(location.path, path);
        assert_eq!((location.line, location.column), (2, 1));
        assert!(error.to_string().contains("dispose_actoin"), "{error}");
        assert!(error.to_string().contains("dispose_action"), "{error}");
    }

    #[test]
    fn a_bad_environment_value_is_fatal_and_names_the_variable() {
        let home = tempfile::tempdir().expect("a temp directory");
        let environment = Environment::from_pairs([
            (
                "XDG_CONFIG_HOME".to_owned(),
                home.path().display().to_string(),
            ),
            ("CABALMAIL_CACHE_MAX_MB".to_owned(), "lots".to_owned()),
        ]);
        let error = load(&environment, &[]).expect_err("the load fails");
        assert_eq!(
            error.to_string(),
            "invalid value for CABALMAIL_CACHE_MAX_MB: must be a whole number"
        );
    }

    /// A stale `CABALMAIL_*` variable in a shell profile is reported, not
    /// fatal — unlike a file, the environment is not necessarily something the
    /// user is editing right now.
    #[test]
    fn an_unknown_environment_variable_warns() {
        let home = tempfile::tempdir().expect("a temp directory");
        let environment = Environment::from_pairs([
            (
                "XDG_CONFIG_HOME".to_owned(),
                home.path().display().to_string(),
            ),
            (
                "CABALMAIL_SMTP_SERVER".to_owned(),
                "mail.example".to_owned(),
            ),
        ]);
        let loaded = load(&environment, &[]).expect("the load succeeds");
        assert_eq!(
            loaded.warnings,
            vec!["ignoring unknown environment variable CABALMAIL_SMTP_SERVER"]
        );
    }

    #[test]
    fn writing_a_setting_creates_the_user_file_and_is_read_back() {
        let home = tempfile::tempdir().expect("a temp directory");
        let environment = environment(home.path(), None);
        let settings = Settings::defaults();

        let path = write_user_setting(
            &environment,
            &settings,
            Key::DisposeAction,
            &Value::Text("trash".to_owned()),
        )
        .expect("the write succeeds");
        assert_eq!(path, home.path().join("cabalmail").join("config.toml"));

        let loaded = load(&environment, &[]).expect("the load succeeds");
        assert_eq!(loaded.settings.text(Key::DisposeAction), "trash");
        assert_eq!(
            loaded.settings.source(Key::DisposeAction),
            &Source::UserFile(path)
        );
    }

    #[test]
    fn the_report_shows_values_provenance_and_the_restart_legend() {
        let home = tempfile::tempdir().expect("a temp directory");
        write_config(home.path(), "[preferences]\ndispose_action = \"trash\"\n");
        let environment = environment(home.path(), None);
        let loaded = load(&environment, &[]).expect("the load succeeds");

        let report = render_report(&loaded);
        assert!(report.contains("[preferences]"), "{report}");
        assert!(report.contains("[preferences.linux]"), "{report}");
        assert!(report.contains("[local]"), "{report}");
        assert!(
            report.contains("dispose_action") && report.contains("user file"),
            "{report}"
        );
        assert!(report.contains("theme"), "{report}");
        assert!(report.contains("control_domain *"), "{report}");
        assert!(
            report.contains("* takes effect on the next start"),
            "{report}"
        );
        for key in Key::ALL {
            assert!(
                report.contains(key.name()),
                "{key} is missing from the report"
            );
        }
    }
}

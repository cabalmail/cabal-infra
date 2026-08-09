//! Where configuration lives, and the environment that decides.
//!
//! The process environment is captured once into an [`Environment`] rather than
//! read through `std::env` at each use. Two reasons, and both matter: it makes
//! every path in this module testable without mutating global state (which
//! edition 2024 made `unsafe`, correctly — a parallel test that sets a variable
//! races every other test in the binary), and it means one run resolves one set
//! of paths even if something in-process changes the environment later.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

/// The directory this client owns inside each XDG base directory.
pub const APP_DIRECTORY: &str = "cabalmail";

/// The configuration file's name inside [`APP_DIRECTORY`].
pub const CONFIG_FILE: &str = "config.toml";

/// A snapshot of the environment variables configuration resolution reads.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Environment {
    vars: BTreeMap<String, String>,
}

impl Environment {
    /// Captures the process environment.
    #[must_use]
    pub fn from_process() -> Self {
        Self {
            vars: std::env::vars().collect(),
        }
    }

    /// Builds an environment from explicit pairs — the form tests use, so they
    /// never touch the process environment.
    pub fn from_pairs<K, V, I>(pairs: I) -> Self
    where
        I: IntoIterator<Item = (K, V)>,
        K: Into<String>,
        V: Into<String>,
    {
        Self {
            vars: pairs
                .into_iter()
                .map(|(key, value)| (key.into(), value.into()))
                .collect(),
        }
    }

    /// A variable's value, if it is set and non-empty. The XDG spec treats an
    /// empty value as unset, and so does every `CABALMAIL_*` lookup — an empty
    /// override is almost always a shell expansion that came up dry, not an
    /// intent to set a setting to nothing.
    #[must_use]
    pub fn get(&self, name: &str) -> Option<&str> {
        self.vars
            .get(name)
            .map(String::as_str)
            .filter(|value| !value.is_empty())
    }

    /// Every `CABALMAIL_*` variable, in name order.
    pub fn cabalmail_vars(&self) -> impl Iterator<Item = (&str, &str)> {
        self.vars
            .iter()
            .filter(|(name, value)| name.starts_with("CABALMAIL_") && !value.is_empty())
            .map(|(name, value)| (name.as_str(), value.as_str()))
    }

    /// The user's configuration directory.
    ///
    /// `$XDG_CONFIG_HOME` when it holds an absolute path; otherwise whatever
    /// the platform's base directories resolve to. `$HOME/.config` is never
    /// spelled out here — the spec says relative paths in the variable are
    /// ignored, and hand-rolling the fallback is how a client ends up writing
    /// to the wrong place on a system that arranges things differently.
    #[must_use]
    pub fn config_home(&self) -> Option<PathBuf> {
        if let Some(path) = self.get("XDG_CONFIG_HOME").map(PathBuf::from)
            && path.is_absolute()
        {
            return Some(path);
        }
        directories::BaseDirs::new().map(|dirs| dirs.config_dir().to_path_buf())
    }

    /// The system configuration directories, in precedence order.
    ///
    /// `$XDG_CONFIG_DIRS` is a colon-separated list, highest precedence first,
    /// defaulting to `/etc/xdg`. Relative entries are ignored per the spec.
    #[must_use]
    pub fn config_dirs(&self) -> Vec<PathBuf> {
        match self.get("XDG_CONFIG_DIRS") {
            Some(raw) => raw
                .split(':')
                .filter(|entry| !entry.is_empty())
                .map(PathBuf::from)
                .filter(|path| path.is_absolute())
                .collect(),
            None => vec![PathBuf::from("/etc/xdg")],
        }
    }

    /// The user's `config.toml`.
    #[must_use]
    pub fn user_config_file(&self) -> Option<PathBuf> {
        self.config_home().map(|dir| config_file_in(&dir))
    }

    /// Every system `config.toml`, in precedence order. These need not exist;
    /// the loader skips the ones that do not.
    #[must_use]
    pub fn system_config_files(&self) -> Vec<PathBuf> {
        self.config_dirs()
            .iter()
            .map(|dir| config_file_in(dir))
            .collect()
    }
}

/// `<dir>/cabalmail/config.toml`.
fn config_file_in(dir: &Path) -> PathBuf {
    dir.join(APP_DIRECTORY).join(CONFIG_FILE)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_absolute_config_home_relocates_the_user_file() {
        let env = Environment::from_pairs([("XDG_CONFIG_HOME", "/tmp/xdg-home")]);
        assert_eq!(
            env.user_config_file(),
            Some(PathBuf::from("/tmp/xdg-home/cabalmail/config.toml"))
        );
    }

    /// The spec says a relative entry is ignored, not resolved against the
    /// working directory — honouring one would make the config path depend on
    /// where the user happened to launch the client from.
    #[test]
    fn a_relative_config_home_is_ignored() {
        let env = Environment::from_pairs([("XDG_CONFIG_HOME", "relative/path")]);
        let resolved = env.user_config_file();
        assert!(
            resolved.is_none_or(|path| !path.starts_with("relative")),
            "a relative XDG_CONFIG_HOME was honoured"
        );
    }

    #[test]
    fn config_dirs_default_to_etc_xdg_and_keep_their_order() {
        let env = Environment::default();
        assert_eq!(
            env.system_config_files(),
            vec![PathBuf::from("/etc/xdg/cabalmail/config.toml")]
        );

        let env = Environment::from_pairs([("XDG_CONFIG_DIRS", "/one:/two")]);
        assert_eq!(
            env.system_config_files(),
            vec![
                PathBuf::from("/one/cabalmail/config.toml"),
                PathBuf::from("/two/cabalmail/config.toml"),
            ]
        );
    }

    #[test]
    fn relative_and_empty_config_dirs_entries_are_dropped() {
        let env = Environment::from_pairs([("XDG_CONFIG_DIRS", "/one::relative:/two")]);
        assert_eq!(
            env.system_config_files(),
            vec![
                PathBuf::from("/one/cabalmail/config.toml"),
                PathBuf::from("/two/cabalmail/config.toml"),
            ]
        );
    }

    #[test]
    fn empty_variables_read_as_unset() {
        let env = Environment::from_pairs([("XDG_CONFIG_DIRS", ""), ("CABALMAIL_THEME", "")]);
        assert_eq!(env.get("XDG_CONFIG_DIRS"), None);
        assert_eq!(
            env.system_config_files(),
            vec![PathBuf::from("/etc/xdg/cabalmail/config.toml")]
        );
        assert_eq!(env.cabalmail_vars().count(), 0);
    }

    #[test]
    fn cabalmail_vars_are_listed_in_name_order() {
        let env = Environment::from_pairs([
            ("CABALMAIL_THEME", "dark"),
            ("PATH", "/usr/bin"),
            ("CABALMAIL_LOG_LEVEL", "debug"),
        ]);
        let found: Vec<(&str, &str)> = env.cabalmail_vars().collect();
        assert_eq!(
            found,
            vec![
                ("CABALMAIL_LOG_LEVEL", "debug"),
                ("CABALMAIL_THEME", "dark"),
            ]
        );
    }
}

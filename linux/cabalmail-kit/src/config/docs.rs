//! Generated documentation for the key table.
//!
//! `config.example.toml` and the KEYS section of `cabalmail.5` are produced
//! here, from the same table the parser reads. They cannot drift from what the
//! client accepts, because there is nothing to drift *from* — a key added to
//! the schema appears in both, and `xtask`'s generated-docs test fails CI if
//! the committed files are stale.
//!
//! Both files live in `cabalmail-gtk/data/`, since packaging installs them.

use super::schema::{Key, Reload, Scope};

/// The commented reference file installed to `/usr/share/doc/cabalmail/`.
///
/// Every setting appears at its built-in default, commented out. A commented
/// line is a setting with no local opinion — copying the file wholesale must
/// not turn every default into an assertion that would then push to the
/// server.
#[must_use]
pub fn example_toml() -> String {
    let mut out = String::new();
    out.push_str(
        "# Cabalmail configuration reference.\n\
         #\n\
         # Copy the settings you want into your own file at\n\
         # $XDG_CONFIG_HOME/cabalmail/config.toml (usually\n\
         # ~/.config/cabalmail/config.toml), or run `cabalmail config set`.\n\
         # Uncommenting a line makes it your setting; leaving it commented\n\
         # means you have no local opinion and the value comes from elsewhere.\n\
         #\n\
         # `cabalmail --print-config` shows what is in force and where each\n\
         # value came from. Full documentation: man 5 cabalmail.\n\
         #\n\
         # Generated from the client's key table — do not edit by hand.\n",
    );

    for scope in Scope::ALL.iter().copied() {
        out.push_str("\n\n");
        for line in comment(scope.summary()) {
            out.push_str(&line);
            out.push('\n');
        }
        out.push_str(&format!("[{}]\n", scope.section()));

        for key in Key::in_scope(scope) {
            let spec = key.spec();
            out.push('\n');
            for line in comment(spec.doc) {
                out.push_str(&line);
                out.push('\n');
            }
            out.push_str(&format!("# Accepts {}.", spec.kind.describe()));
            if spec.reload == Reload::Restart {
                out.push_str(" Takes effect on the next start.");
            }
            out.push('\n');
            let value = spec
                .kind
                .parse(spec.default)
                .expect("a default that does not parse is caught by a schema test");
            out.push_str(&format!("#{} = {}\n", key.name(), value.to_toml()));
        }
    }
    out
}

/// The KEYS section of `cabalmail.5.md`, between its generated-block markers.
///
/// Markdown rather than roff: the man page source is markdown, converted at
/// packaging time, and keeping the generated block in the same dialect as the
/// prose around it means the file is readable in a browser as well as in
/// `man`.
#[must_use]
pub fn man_keys_markdown() -> String {
    let mut out = String::new();
    for scope in Scope::ALL.iter().copied() {
        out.push_str(&format!("### `[{}]`\n\n", scope.section()));
        out.push_str(scope.summary());
        out.push_str("\n\n");

        for key in Key::in_scope(scope) {
            let spec = key.spec();
            out.push_str(&format!("#### `{}`\n\n", key.name()));
            out.push_str(spec.doc);
            out.push_str("\n\n");
            out.push_str(&format!("*Accepts:* {}.  \n", spec.kind.describe()));
            out.push_str(&format!(
                "*Default:* `{}`.  \n",
                spec.kind
                    .parse(spec.default)
                    .expect("a default that does not parse is caught by a schema test")
                    .to_toml()
            ));
            out.push_str(&format!(
                "*Environment:* `{}`. *Option:* `{}`.  \n",
                spec.env_var(),
                spec.flag()
            ));
            out.push_str(&format!(
                "*Applies:* {}.  \n",
                match spec.reload {
                    Reload::Live => "immediately",
                    Reload::Restart => "on the next start",
                }
            ));
            out.push_str(&format!("*Syncs:* {}.\n\n", sync_phrase(scope)));
        }
    }
    out.trim_end().to_owned() + "\n"
}

/// How far this scope's values travel, in a sentence fragment.
fn sync_phrase(scope: Scope) -> &'static str {
    match scope {
        Scope::Universal => "to every device you use, on every platform",
        Scope::Linux => "to your other Linux machines only",
        Scope::Local => "never — this machine only",
    }
}

/// Prose as `# `-prefixed comment lines.
fn comment(text: &str) -> Vec<String> {
    super::file::wrap_comment(text, 74)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::file;
    use crate::config::settings::Settings;
    use std::path::Path;

    /// The example file has to be valid TOML that the parser accepts — with
    /// every setting commented out, so it says nothing.
    #[test]
    fn the_example_file_parses_and_asserts_nothing() {
        let text = example_toml();
        let found =
            file::parse(Path::new("config.example.toml"), &text).expect("the example file parses");
        assert!(found.is_empty(), "the example file sets {found:?}");
    }

    /// Uncommenting the whole file must produce the defaults, not an error —
    /// which is what a user does when they copy it and start editing.
    #[test]
    fn the_example_file_uncommented_is_exactly_the_defaults() {
        let uncommented: String = example_toml()
            .lines()
            .map(|line| match line.strip_prefix('#') {
                // Prose comments start `# `; a setting line is `#key = value`.
                Some(rest) if !rest.starts_with([' ', '#']) && !rest.is_empty() => rest.to_owned(),
                _ => line.to_owned(),
            })
            .collect::<Vec<_>>()
            .join("\n");

        let found = file::parse(Path::new("config.example.toml"), &uncommented)
            .expect("the uncommented example parses");
        let defaults = Settings::defaults();
        assert_eq!(found.len(), Key::ALL.len());
        for (key, value) in found {
            assert_eq!(&value, defaults.get(key), "{key}");
        }
    }

    #[test]
    fn every_key_appears_in_both_generated_documents() {
        let example = example_toml();
        let man = man_keys_markdown();
        for key in Key::ALL.iter().copied() {
            assert!(
                example.contains(&format!("#{} = ", key.name())),
                "{key} is missing from config.example.toml"
            );
            assert!(
                man.contains(&format!("#### `{}`", key.name())),
                "{key} is missing from the man page"
            );
            assert!(
                man.contains(&key.spec().env_var()),
                "{key}'s environment variable is missing from the man page"
            );
        }
        for scope in Scope::ALL.iter().copied() {
            assert!(example.contains(&format!("[{}]", scope.section())));
            assert!(man.contains(&format!("### `[{}]`", scope.section())));
        }
    }

    /// The man page states where a value travels, per scope. Getting this
    /// wrong is how a user ends up surprised that a setting followed them to
    /// another machine.
    #[test]
    fn the_man_page_states_each_scope_s_reach() {
        let man = man_keys_markdown();
        for scope in Scope::ALL.iter().copied() {
            assert!(
                man.contains(sync_phrase(scope)),
                "{scope} has no sync phrase"
            );
        }
    }
}

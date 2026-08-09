//! Reading and writing `config.toml`.
//!
//! Two properties make the file safe to share with the user's editor, and both
//! are load-bearing for the three-writer model (file, Settings UI, server) the
//! plan settles on:
//!
//! - **Writes are atomic** — a temporary file in the same directory, then
//!   `rename(2)`. A reader sees either the old file or the new one, never a
//!   truncated one, and an open editor's `:w` cannot interleave with a client
//!   write.
//! - **Comments and key order survive** — `toml_edit`, not a serializer. A
//!   client rewrite touches only the values it changed; the user's comments,
//!   ordering, and spacing come back out exactly as they went in.

use std::io::Write as _;
use std::path::Path;

use toml_edit::{Document, DocumentMut, InlineTable, Item, Table, TableLike};

use super::error::{ConfigError, ConfigErrorKind, Location, nearest_key_name};
use super::schema::{Key, Scope};
use super::settings::Settings;
use super::value::Value;

/// The file's contents, or `None` if it does not exist.
///
/// A missing file is not an error: no configuration file is the normal state
/// on a fresh install, and the loader walks several paths that usually are not
/// there.
///
/// # Errors
///
/// If the file exists but cannot be read.
pub fn read(path: &Path) -> Result<Option<String>, ConfigError> {
    match std::fs::read_to_string(path) {
        Ok(text) => Ok(Some(text)),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(error) => Err(ConfigError::new(ConfigErrorKind::Io {
            path: path.to_path_buf(),
            detail: error.to_string(),
        })),
    }
}

/// Parses one configuration file into the key/value pairs it sets.
///
/// Every failure carries the position that produced it. Nothing is skipped or
/// defaulted on the way past: an unknown key, a key in a section that
/// disagrees with its sync scope, or a value the key does not accept all stop
/// the parse. `path` is used for error messages only — the caller supplies the
/// text, so an in-memory document can be parsed under the name it will have.
///
/// # Errors
///
/// If the document is not valid TOML, or says something the schema does not
/// allow.
pub fn parse(path: &Path, text: &str) -> Result<Vec<(Key, Value)>, ConfigError> {
    let document = Document::parse(text).map_err(|error| {
        let location = error
            .span()
            .map(|span| Location::in_text(path, text, span.start));
        let kind = ConfigErrorKind::Syntax(error.message().to_owned());
        location.map_or_else(
            || ConfigError::new(kind.clone()),
            |location| ConfigError::at(location, kind.clone()),
        )
    })?;

    let mut found = Vec::new();
    let root = document.as_table();
    for (name, item) in root.iter() {
        let position = || key_location(path, text, root, name);
        match Scope::from_section(name) {
            // `[local]`, and `[preferences]` with its `linux` child.
            Some(scope @ (Scope::Universal | Scope::Local)) => {
                let table = as_table(item).ok_or_else(|| {
                    ConfigError::at(
                        position(),
                        ConfigErrorKind::UnknownSection {
                            name: name.to_owned(),
                        },
                    )
                })?;
                scan(path, text, table, scope, &mut found)?;
            }
            // `preferences.linux` never appears at the root: TOML spells the
            // child table as a member of its parent.
            Some(Scope::Linux) | None => {
                return Err(misplaced_at_root(path, text, root, name, item));
            }
        }
    }
    Ok(found)
}

/// Walks one section's entries, resolving each against the schema.
fn scan(
    path: &Path,
    text: &str,
    table: &dyn TableLike,
    scope: Scope,
    found: &mut Vec<(Key, Value)>,
) -> Result<(), ConfigError> {
    for (name, item) in table.iter() {
        let position = || key_location(path, text, table, name);

        // A nested table is a subsection. `[preferences.linux]` is the only
        // one there is; anything else is a section nobody declares — unless
        // the name is a declared *key*, in which case the user wrote a table
        // where a value belongs and the value path below says so in the terms
        // they were reaching for.
        if let Some(child) = as_table(item)
            && Key::from_name(name).is_none()
        {
            if scope == Scope::Universal && name == "linux" {
                scan(path, text, child, Scope::Linux, found)?;
                continue;
            }
            return Err(ConfigError::at(
                position(),
                ConfigErrorKind::UnknownSection {
                    name: format!("{}.{name}", scope.section()),
                },
            ));
        }

        let Some(key) = Key::from_name(name) else {
            return Err(ConfigError::at(
                position(),
                ConfigErrorKind::UnknownKey {
                    name: name.to_owned(),
                    section: Some(scope.section().to_owned()),
                    suggestion: nearest_key_name(name),
                },
            ));
        };
        // The section is the file's rendering of the key's sync scope, so a
        // key in the wrong one is a statement about where the value may travel
        // that contradicts the schema. Saying which section it belongs in is
        // the whole point — the user is trying to reach a setting, not to
        // learn that a section exists.
        if key.scope() != scope {
            return Err(ConfigError::at(
                position(),
                ConfigErrorKind::WrongSection {
                    key,
                    found: Some(scope.section().to_owned()),
                    expected: key.scope(),
                },
            ));
        }

        let Some(raw) = item.as_value() else {
            return Err(ConfigError::at(
                position(),
                ConfigErrorKind::NotAValue {
                    name: name.to_owned(),
                    section: scope.section().to_owned(),
                },
            ));
        };
        let value = from_toml(raw).ok_or_else(|| {
            ConfigError::at(
                value_location(path, text, item, table, name),
                ConfigErrorKind::InvalidValue {
                    key,
                    detail: format!(
                        "expected {}, found {}",
                        key.kind().expects(),
                        toml_type_name(raw)
                    ),
                },
            )
        })?;
        let value = key.kind().coerce(value).map_err(|detail| {
            ConfigError::at(
                value_location(path, text, item, table, name),
                ConfigErrorKind::InvalidValue { key, detail },
            )
        })?;
        found.push((key, value));
    }
    Ok(())
}

/// A key or table at the document root, where no setting belongs.
fn misplaced_at_root(
    path: &Path,
    text: &str,
    root: &dyn TableLike,
    name: &str,
    item: &Item,
) -> ConfigError {
    let location = key_location(path, text, root, name);
    if let Some(key) = Key::from_name(name) {
        return ConfigError::at(
            location,
            ConfigErrorKind::WrongSection {
                key,
                found: None,
                expected: key.scope(),
            },
        );
    }
    if as_table(item).is_some() {
        return ConfigError::at(
            location,
            ConfigErrorKind::UnknownSection {
                name: name.to_owned(),
            },
        );
    }
    ConfigError::at(
        location,
        ConfigErrorKind::UnknownKey {
            name: name.to_owned(),
            section: None,
            suggestion: nearest_key_name(name),
        },
    )
}

/// The table behind an item, whether it was written as a section header, a
/// dotted key, or an inline table.
///
/// All three spellings are the same document. `[preferences.linux]`,
/// `linux.close_to_tray = true`, and `linux = { close_to_tray = true }` say
/// one thing, and a user who reaches for the third should not be told they
/// have a typo. `Item::as_table` sees only the first two — `toml_edit` models
/// an inline table as a *value* — so the parser walks `TableLike`, which
/// covers both representations.
fn as_table(item: &Item) -> Option<&dyn TableLike> {
    item.as_table_like()
}

/// A TOML value converted into a [`Value`], or `None` for the shapes no key
/// accepts (floats, dates, tables of anything but strings).
fn from_toml(value: &toml_edit::Value) -> Option<Value> {
    match value {
        toml_edit::Value::String(text) => Some(Value::Text(text.value().clone())),
        toml_edit::Value::Boolean(flag) => Some(Value::Flag(*flag.value())),
        toml_edit::Value::Integer(number) => Some(Value::Number(*number.value())),
        toml_edit::Value::Array(array) => {
            let mut items = Vec::with_capacity(array.len());
            for entry in array {
                items.push(entry.as_str()?.to_owned());
            }
            Some(Value::List(items))
        }
        _ => None,
    }
}

/// The TOML type name, for a "found a float" message.
fn toml_type_name(value: &toml_edit::Value) -> &'static str {
    match value {
        toml_edit::Value::String(_) => "a string",
        toml_edit::Value::Integer(_) => "an integer",
        toml_edit::Value::Float(_) => "a decimal number",
        toml_edit::Value::Boolean(_) => "a boolean",
        toml_edit::Value::Datetime(_) => "a date",
        toml_edit::Value::Array(_) => "an array",
        toml_edit::Value::InlineTable(_) => "a table",
    }
}

/// Where a key is written.
fn key_location(path: &Path, text: &str, table: &dyn TableLike, name: &str) -> Location {
    let offset = table
        .key(name)
        .and_then(toml_edit::Key::span)
        .map_or(0, |span| span.start);
    Location::in_text(path, text, offset)
}

/// Where a key's value is written, falling back to the key itself.
fn value_location(
    path: &Path,
    text: &str,
    item: &Item,
    table: &dyn TableLike,
    name: &str,
) -> Location {
    item.span().map_or_else(
        || key_location(path, text, table, name),
        |span| Location::in_text(path, text, span.start),
    )
}

/// Writes one key into `path`, creating the file from `settings` if it is not
/// there yet.
///
/// Only the named value is touched. Everything else in the file — comments,
/// key order, spacing, even the alignment of the `=` — comes back out as it
/// went in, because the document is edited rather than re-serialized.
///
/// A file that does not exist is materialized in full first, from the store's
/// [persisted](Settings::persisted) view — the values in force with this run's
/// flags and `CABALMAIL_*` variables left out. That is the same file the
/// client writes on first sign-in: a user should not have to discover what is
/// editable by reading the manual, and a one-key file would teach them
/// nothing.
///
/// # Errors
///
/// If the existing file cannot be read or is not valid TOML, or if the write
/// fails.
pub fn set_key(
    path: &Path,
    settings: &Settings,
    key: Key,
    value: &Value,
) -> Result<(), ConfigError> {
    let text = match read(path)? {
        Some(text) => text,
        None => render(settings),
    };
    // Validate before editing: a file the client cannot make sense of is one
    // it must not rewrite, and the user gets the same positioned error they
    // would have got at startup rather than a mangled file.
    parse(path, &text)?;

    let mut document: DocumentMut = text.parse::<DocumentMut>().map_err(|error| {
        let location = error
            .span()
            .map(|span| Location::in_text(path, &text, span.start));
        let kind = ConfigErrorKind::Syntax(error.message().to_owned());
        location.map_or_else(
            || ConfigError::new(kind.clone()),
            |location| ConfigError::at(location, kind.clone()),
        )
    })?;

    let table = section_mut(&mut document, key.scope());
    let item = Item::Value(to_toml(value));
    if let Some(existing) = table.get_mut(key.name()) {
        // Keep the value's own decor so a hand-aligned or commented line keeps
        // its shape across a client write.
        let decor = existing.as_value().map(|value| value.decor().clone());
        *existing = item;
        if let (Some(decor), Some(value)) = (decor, existing.as_value_mut()) {
            *value.decor_mut() = decor;
        }
    } else {
        table.insert(key.name(), item);
    }

    write_atomic(path, &document.to_string())
}

/// The table a scope's keys live in, creating it if it is absent.
///
/// `TableLike` rather than `Table` for the same reason the parser walks it:
/// the section may have been written inline, and the write has to land in the
/// document the user actually has rather than panic on it.
fn section_mut(document: &mut DocumentMut, scope: Scope) -> &mut dyn TableLike {
    let root = match scope {
        Scope::Local => "local",
        Scope::Universal | Scope::Linux => "preferences",
    };
    let section = document
        .entry(root)
        .or_insert_with(|| Item::Table(Table::new()));
    if scope != Scope::Linux {
        return section
            .as_table_like_mut()
            .expect("the section is a table — the parse before this rejected anything else");
    }

    // A child the file does not have yet is spelled the way its parent is: a
    // section header under `[preferences]`, an inline table inside an inline
    // one. Writing a `Table` into an inline table is not representable, and
    // `TableLike::insert` panics rather than say so.
    let inline = section.is_inline_table();
    let parent = section
        .as_table_like_mut()
        .expect("[preferences] is a table — the parse before this rejected anything else");
    if !parent.contains_key("linux") {
        let child = if inline {
            Item::Value(toml_edit::Value::InlineTable(InlineTable::new()))
        } else {
            Item::Table(Table::new())
        };
        parent.insert("linux", child);
    }
    parent
        .get_mut("linux")
        .and_then(Item::as_table_like_mut)
        .expect("[preferences.linux] is a table — the parse before this rejected anything else")
}

/// A [`Value`] as a TOML value.
fn to_toml(value: &Value) -> toml_edit::Value {
    match value {
        Value::Text(text) => text.as_str().into(),
        Value::Flag(flag) => (*flag).into(),
        Value::Number(number) => (*number).into(),
        Value::List(items) => items.iter().map(String::as_str).collect(),
    }
}

/// Renders a complete `config.toml` from the values currently in force.
///
/// This is the file the client materializes on first sign-in: every key
/// present, each section under the sentence that says how far its values
/// travel. Transient overrides (flags and environment variables) are
/// deliberately *not* what is written — the file records settings, not this
/// invocation's arguments — which is why every value comes from
/// [`Settings::persisted`] rather than from what is in force.
#[must_use]
pub fn render(settings: &Settings) -> String {
    let mut out = String::new();
    out.push_str(
        "# Cabalmail configuration.\n\
         #\n\
         # Edit this file, or use Settings, or another device — the three are\n\
         # peers, and a change through any of them reaches the other two.\n\
         # `cabalmail --print-config` shows what is in force and where each\n\
         # value came from. See cabalmail(5) for every setting.\n",
    );

    for scope in Scope::ALL.iter().copied() {
        out.push('\n');
        for line in wrap_comment(scope.summary(), 74) {
            out.push_str(&line);
            out.push('\n');
        }
        out.push_str(&format!("[{}]\n", scope.section()));

        let keys: Vec<Key> = Key::in_scope(scope).collect();
        let width = keys
            .iter()
            .map(|key| key.name().len())
            .max()
            .unwrap_or_default();
        for key in keys {
            let value = settings.persisted(key).value.to_toml();
            out.push_str(&format!("{:width$} = {value}\n", key.name(), width = width));
        }
    }
    out
}

/// Wraps prose into `# `-prefixed comment lines.
pub(super) fn wrap_comment(text: &str, width: usize) -> Vec<String> {
    let mut lines = Vec::new();
    let mut current = String::from("#");
    for word in text.split_whitespace() {
        if current.chars().count() + 1 + word.chars().count() > width && current != "#" {
            lines.push(std::mem::replace(&mut current, String::from("#")));
        }
        current.push(' ');
        current.push_str(word);
    }
    if current != "#" {
        lines.push(current);
    }
    lines
}

/// Writes `contents` to `path` atomically: a temporary file in the same
/// directory, flushed and synced, then renamed over the target.
///
/// The temporary file has to be a sibling — `rename(2)` is only atomic within
/// a filesystem, and `$TMPDIR` is frequently a different one.
///
/// # Errors
///
/// If the directory cannot be created, or the write or rename fails.
pub fn write_atomic(path: &Path, contents: &str) -> Result<(), ConfigError> {
    let io_error = |detail: String| {
        ConfigError::new(ConfigErrorKind::Io {
            path: path.to_path_buf(),
            detail,
        })
    };

    let directory = path.parent().unwrap_or_else(|| Path::new("."));
    std::fs::create_dir_all(directory).map_err(|error| io_error(error.to_string()))?;

    let mut temporary = tempfile::Builder::new()
        .prefix(".config.toml.")
        .suffix(".tmp")
        .tempfile_in(directory)
        .map_err(|error| io_error(error.to_string()))?;
    temporary
        .write_all(contents.as_bytes())
        .and_then(|()| temporary.as_file().sync_all())
        .map_err(|error| io_error(error.to_string()))?;
    temporary
        .persist(path)
        .map_err(|error| io_error(error.to_string()))?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::error::ConfigErrorKind;
    use crate::config::settings::Source;

    fn parse_ok(text: &str) -> Vec<(Key, Value)> {
        parse(Path::new("/tmp/config.toml"), text).expect("the document parses")
    }

    fn parse_err(text: &str) -> ConfigError {
        parse(Path::new("/tmp/config.toml"), text).expect_err("the document is rejected")
    }

    #[test]
    fn a_populated_file_yields_every_key_it_sets() {
        let found = parse_ok(
            r#"
[preferences]
dispose_action = "trash"
signature = "-- \nsent from a machine I control"

[preferences.linux]
close_to_tray = true
notification_actions = ["open", "archive"]

[local]
control_domain = "stage.cabalmail.example"
cache_max_mb = 500
"#,
        );
        assert_eq!(
            found,
            vec![
                (Key::DisposeAction, Value::Text("trash".to_owned())),
                (
                    Key::Signature,
                    Value::Text("-- \nsent from a machine I control".to_owned())
                ),
                (Key::CloseToTray, Value::Flag(true)),
                (
                    Key::NotificationActions,
                    Value::List(vec!["open".to_owned(), "archive".to_owned()])
                ),
                (
                    Key::ControlDomain,
                    Value::Text("stage.cabalmail.example".to_owned())
                ),
                (Key::CacheMaxMb, Value::Number(500)),
            ]
        );
    }

    /// TOML spells a table three ways and means one thing by all of them. A
    /// user who writes the inline form is not making a mistake, and telling
    /// them `linux` is an unknown setting sends them hunting for a typo that
    /// is not there.
    #[test]
    fn every_spelling_of_a_table_reads_the_same() {
        let expected = vec![
            (Key::Theme, Value::Text("dark".to_owned())),
            (Key::CloseToTray, Value::Flag(true)),
        ];
        for text in [
            "[preferences]\ntheme = \"dark\"\n\n[preferences.linux]\nclose_to_tray = true\n",
            "[preferences]\ntheme = \"dark\"\nlinux.close_to_tray = true\n",
            "[preferences]\ntheme = \"dark\"\nlinux = { close_to_tray = true }\n",
            "preferences = { theme = \"dark\", linux = { close_to_tray = true } }\n",
        ] {
            assert_eq!(parse_ok(text), expected, "{text}");
        }
    }

    /// The inline spellings have to reach the same errors as the section
    /// form — accepting the syntax is not accepting what it says.
    #[test]
    fn an_inline_table_is_checked_like_the_section_it_stands_for() {
        assert!(matches!(
            parse_err("[preferences]\nlinux = { theme = \"dark\" }\n").kind,
            ConfigErrorKind::WrongSection {
                key: Key::Theme,
                expected: Scope::Universal,
                ..
            }
        ));
        assert!(matches!(
            parse_err("[preferences]\nlinux = { close_to_trey = true }\n").kind,
            ConfigErrorKind::UnknownKey {
                suggestion: Some("close_to_tray"),
                ..
            }
        ));
        assert!(matches!(
            parse_err("[preferences]\nnope = { a = 1 }\n").kind,
            ConfigErrorKind::UnknownSection { .. }
        ));
    }

    /// A declared key written as a table is a value the key does not accept,
    /// not a section nobody declared. Walking `TableLike` makes it easy to
    /// report the second, which would send the user looking for a section
    /// they never wrote.
    #[test]
    fn a_key_given_a_table_reports_the_value_not_a_section() {
        assert!(matches!(
            parse_err("[preferences]\ntheme = { a = 1 }\n").kind,
            ConfigErrorKind::InvalidValue {
                key: Key::Theme,
                ..
            }
        ));
        assert!(matches!(
            parse_err("[preferences]\n[preferences.theme]\na = 1\n").kind,
            ConfigErrorKind::NotAValue { .. }
        ));
    }

    #[test]
    fn an_empty_file_sets_nothing() {
        assert!(parse_ok("").is_empty());
        assert!(parse_ok("# just a comment\n").is_empty());
    }

    /// A typo'd key needs to be told, with the position an editor can jump to.
    #[test]
    fn a_typo_fails_with_its_position_and_a_suggestion() {
        let error = parse_err("[preferences]\nmark_as_reed = \"on_open\"\n");
        let location = error.location.expect("the error carries a position");
        assert_eq!((location.line, location.column), (2, 1));
        assert!(matches!(
            error.kind,
            ConfigErrorKind::UnknownKey {
                suggestion: Some("mark_as_read"),
                ..
            }
        ));
    }

    /// Both directions, for all three scopes — the section is the file's
    /// rendering of the sync scope, and getting it wrong has to name the
    /// section the key belongs in rather than silently accepting a value that
    /// would then sync somewhere it should not.
    #[test]
    fn a_key_in_the_wrong_section_names_the_right_one() {
        let cases = [
            // universal key, elsewhere
            (
                "[preferences.linux]\ntheme = \"dark\"\n",
                Key::Theme,
                Scope::Universal,
                "preferences.linux",
            ),
            (
                "[local]\ntheme = \"dark\"\n",
                Key::Theme,
                Scope::Universal,
                "local",
            ),
            // platform-scoped key, elsewhere
            (
                "[preferences]\nclose_to_tray = true\n",
                Key::CloseToTray,
                Scope::Linux,
                "preferences",
            ),
            (
                "[local]\nclose_to_tray = true\n",
                Key::CloseToTray,
                Scope::Linux,
                "local",
            ),
            // machine-local key, elsewhere
            (
                "[preferences]\nlog_level = \"debug\"\n",
                Key::LogLevel,
                Scope::Local,
                "preferences",
            ),
            (
                "[preferences.linux]\nlog_level = \"debug\"\n",
                Key::LogLevel,
                Scope::Local,
                "preferences.linux",
            ),
        ];

        for (text, key, expected, found) in cases {
            let error = parse_err(text);
            assert_eq!(
                error.kind,
                ConfigErrorKind::WrongSection {
                    key,
                    found: Some(found.to_owned()),
                    expected,
                },
                "{text}"
            );
            assert!(
                error.to_string().contains(expected.section()),
                "the message does not name [{}]: {error}",
                expected.section()
            );
            assert!(error.location.is_some(), "{text}");
        }
    }

    #[test]
    fn a_setting_outside_every_section_is_rejected() {
        let error = parse_err("theme = \"dark\"\n");
        assert_eq!(
            error.kind,
            ConfigErrorKind::WrongSection {
                key: Key::Theme,
                found: None,
                expected: Scope::Universal,
            }
        );
        assert!(error.to_string().contains("the top level"));
    }

    #[test]
    fn an_unknown_section_is_rejected() {
        for text in [
            "[preference]\ntheme = \"dark\"\n",
            "[preferences.mac]\ntheme = \"dark\"\n",
            "[local.cache]\ncache_max_mb = 1\n",
        ] {
            assert!(
                matches!(parse_err(text).kind, ConfigErrorKind::UnknownSection { .. }),
                "{text} was accepted"
            );
        }
    }

    #[test]
    fn a_bad_value_names_the_key_and_points_at_the_value() {
        let error = parse_err("[preferences]\ndispose_action = \"incinerate\"\n");
        let location = error
            .location
            .clone()
            .expect("the error carries a position");
        assert_eq!((location.line, location.column), (2, 18));
        assert!(error.to_string().contains("`archive`"), "{error}");
    }

    #[test]
    fn a_value_of_the_wrong_type_says_what_it_expected() {
        let error = parse_err("[preferences.linux]\nclose_to_tray = \"yes\"\n");
        assert!(
            error
                .to_string()
                .contains("expected a boolean, found a string"),
            "{error}"
        );
        let error = parse_err("[local]\ncache_max_mb = 12.5\n");
        assert!(
            error.to_string().contains("found a decimal number"),
            "{error}"
        );
    }

    #[test]
    fn a_syntax_error_carries_its_position() {
        let error = parse_err("[preferences]\ntheme = \n");
        assert!(matches!(error.kind, ConfigErrorKind::Syntax(_)));
        assert_eq!(error.location.expect("a position").line, 2);
    }

    /// Dotted keys are the same tree written differently, and have to resolve
    /// to the same scopes.
    #[test]
    fn dotted_keys_resolve_like_sections() {
        let found = parse_ok("[preferences]\nlinux.close_to_tray = true\n");
        assert_eq!(found, vec![(Key::CloseToTray, Value::Flag(true))]);

        let error = parse_err("[preferences]\nlinux.theme = \"dark\"\n");
        assert!(matches!(
            error.kind,
            ConfigErrorKind::WrongSection {
                key: Key::Theme,
                ..
            }
        ));
    }

    #[test]
    fn a_rendered_file_round_trips_through_the_parser() {
        let settings = Settings::defaults();
        let text = render(&settings);
        let found = parse_ok(&text);
        assert_eq!(found.len(), Key::ALL.len());
        for (key, value) in found {
            assert_eq!(&value, settings.get(key), "{key} did not round-trip");
        }
    }

    #[test]
    fn a_missing_file_reads_as_absent() {
        let directory = tempfile::tempdir().expect("a temp directory");
        assert_eq!(read(&directory.path().join("config.toml")), Ok(None));
    }

    /// The property the whole three-writer model rests on: a client write
    /// leaves everything it did not change exactly as the user wrote it.
    #[test]
    fn a_write_preserves_comments_order_and_alignment() {
        let directory = tempfile::tempdir().expect("a temp directory");
        let path = directory.path().join("config.toml");
        let original = "\
# my settings, hands off
[preferences]
# I like archive
dispose_action = \"archive\"
theme          = \"dark\"

[local]
log_level = \"debug\"
";
        std::fs::write(&path, original).expect("the fixture writes");

        set_key(
            &path,
            &Settings::defaults(),
            Key::DisposeAction,
            &Value::Text("trash".to_owned()),
        )
        .expect("the write succeeds");

        let written = std::fs::read_to_string(&path).expect("the file reads back");
        assert_eq!(
            written,
            original.replace("dispose_action = \"archive\"", "dispose_action = \"trash\""),
            "the write changed more than the value"
        );
    }

    #[test]
    fn a_write_to_a_missing_file_materializes_every_key() {
        let directory = tempfile::tempdir().expect("a temp directory");
        let path = directory.path().join("nested").join("config.toml");
        let mut settings = Settings::defaults();
        settings.set(Key::Theme, Value::Text("dark".to_owned()), Source::Server);

        set_key(
            &path,
            &settings,
            Key::LogLevel,
            &Value::Text("debug".to_owned()),
        )
        .expect("the write succeeds");

        let written = std::fs::read_to_string(&path).expect("the file reads back");
        let found = parse(&path, &written).expect("the written file parses");
        assert_eq!(found.len(), Key::ALL.len());
        assert!(found.contains(&(Key::LogLevel, Value::Text("debug".to_owned()))));
        assert!(found.contains(&(Key::Theme, Value::Text("dark".to_owned()))));
        assert!(written.contains("# Cabalmail configuration."));
    }

    /// A hand-made file with no `[preferences.linux]` still has to be
    /// writable, and the section it grows has to be the one the parser
    /// expects.
    #[test]
    fn a_write_creates_the_section_it_needs() {
        let directory = tempfile::tempdir().expect("a temp directory");
        let path = directory.path().join("config.toml");
        std::fs::write(&path, "[local]\nlog_level = \"debug\"\n").expect("the fixture writes");

        set_key(
            &path,
            &Settings::defaults(),
            Key::CloseToTray,
            &Value::Flag(true),
        )
        .expect("the write succeeds");

        let written = std::fs::read_to_string(&path).expect("the file reads back");
        let found = parse(&path, &written).expect("the written file parses");
        assert!(
            found.contains(&(Key::CloseToTray, Value::Flag(true))),
            "{written}"
        );
        assert!(found.contains(&(Key::LogLevel, Value::Text("debug".to_owned()))));
    }

    /// Once the parser accepts a spelling the writer has to survive it. A
    /// `Table` is not representable inside an inline table, so a section the
    /// write has to create is spelled the way its parent is.
    #[test]
    fn a_write_into_an_inline_section_keeps_its_spelling() {
        let cases = [
            // The child is already there: edit in place, inline.
            (
                "[preferences]\nlinux = { close_to_tray = true }  # mine\n",
                "[preferences]\nlinux = { close_to_tray = false }  # mine\n",
            ),
            // The child has to be created inside an inline parent.
            (
                "preferences = { theme = \"dark\" }\n",
                "preferences = { theme = \"dark\" , linux = { close_to_tray = false } }\n",
            ),
        ];

        for (original, expected) in cases {
            let directory = tempfile::tempdir().expect("a temp directory");
            let path = directory.path().join("config.toml");
            std::fs::write(&path, original).expect("the fixture writes");

            set_key(
                &path,
                &Settings::defaults(),
                Key::CloseToTray,
                &Value::Flag(false),
            )
            .expect("the write succeeds");

            let written = std::fs::read_to_string(&path).expect("the file reads back");
            assert_eq!(written, expected);
            assert!(
                parse(&path, &written)
                    .expect("the written file parses")
                    .contains(&(Key::CloseToTray, Value::Flag(false))),
                "{written}"
            );
        }
    }

    /// Atomicity is the property that lets an editor and the client write the
    /// same file. A reader either sees the old contents or the new ones — the
    /// target is never opened for writing in place.
    #[test]
    fn writes_land_by_rename_and_leave_no_temporary_behind() {
        let directory = tempfile::tempdir().expect("a temp directory");
        let path = directory.path().join("config.toml");
        write_atomic(&path, "first\n").expect("the first write succeeds");
        write_atomic(&path, "second\n").expect("the second write succeeds");

        assert_eq!(
            std::fs::read_to_string(&path).expect("the file reads back"),
            "second\n"
        );
        let leftovers: Vec<_> = std::fs::read_dir(directory.path())
            .expect("the directory lists")
            .filter_map(Result::ok)
            .map(|entry| entry.file_name())
            .filter(|name| name != "config.toml")
            .collect();
        assert!(
            leftovers.is_empty(),
            "temporary files left behind: {leftovers:?}"
        );
    }

    #[test]
    fn comment_wrapping_stays_within_its_width() {
        let lines = wrap_comment(Scope::Universal.summary(), 40);
        assert!(lines.len() > 1);
        for line in &lines {
            assert!(line.starts_with("# "), "{line}");
            assert!(line.chars().count() <= 40, "{line}");
        }
        let joined = lines
            .iter()
            .map(|line| line.trim_start_matches("# "))
            .collect::<Vec<_>>()
            .join(" ");
        assert_eq!(joined, Scope::Universal.summary());
    }
}

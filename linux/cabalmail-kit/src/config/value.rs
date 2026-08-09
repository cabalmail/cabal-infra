//! Configuration values, and the validation every input path shares.
//!
//! A value reaches the store from four places — a TOML file, an environment
//! variable, a command-line flag, or a server pull — and all four are checked
//! against the same [`Kind`]. That is deliberate: a value the file rejects must
//! not be smuggled in through `CABALMAIL_*`, and a bad value has to be
//! described the same way wherever it came from.

use std::fmt;

use super::schema::Kind;

/// A configuration value, in one of the four shapes [`Kind`] describes.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Value {
    /// Free text, and the storage for [`Kind::Choice`] tokens.
    Text(String),
    /// A boolean.
    Flag(bool),
    /// An integer.
    Number(i64),
    /// An ordered list of tokens.
    List(Vec<String>),
}

impl Value {
    /// The text, for [`Value::Text`].
    #[must_use]
    pub fn as_text(&self) -> Option<&str> {
        match self {
            Self::Text(text) => Some(text),
            _ => None,
        }
    }

    /// The boolean, for [`Value::Flag`].
    #[must_use]
    pub fn as_flag(&self) -> Option<bool> {
        match self {
            Self::Flag(flag) => Some(*flag),
            _ => None,
        }
    }

    /// The integer, for [`Value::Number`].
    #[must_use]
    pub fn as_number(&self) -> Option<i64> {
        match self {
            Self::Number(number) => Some(*number),
            _ => None,
        }
    }

    /// The tokens, for [`Value::List`].
    #[must_use]
    pub fn as_list(&self) -> Option<&[String]> {
        match self {
            Self::List(items) => Some(items),
            _ => None,
        }
    }

    /// The name of the shape, for "expected a boolean, found a string".
    #[must_use]
    pub fn type_name(&self) -> &'static str {
        match self {
            Self::Text(_) => "a string",
            Self::Flag(_) => "a boolean",
            Self::Number(_) => "an integer",
            Self::List(_) => "an array of strings",
        }
    }

    /// The value as it would be written in `config.toml`.
    #[must_use]
    pub fn to_toml(&self) -> String {
        match self {
            Self::Text(text) => toml_escape(text),
            Self::Flag(flag) => flag.to_string(),
            Self::Number(number) => number.to_string(),
            Self::List(items) => {
                let rendered: Vec<String> = items.iter().map(|item| toml_escape(item)).collect();
                format!("[{}]", rendered.join(", "))
            }
        }
    }
}

/// One line, TOML-shaped — what `--print-config` shows. Multi-line text is
/// escaped rather than wrapped, so the column stays a column.
impl fmt::Display for Value {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.to_toml())
    }
}

/// A TOML basic string, with the escapes the format requires.
fn toml_escape(text: &str) -> String {
    let mut out = String::with_capacity(text.len() + 2);
    out.push('"');
    for ch in text.chars() {
        match ch {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            ch if (ch as u32) < 0x20 || ch as u32 == 0x7f => {
                out.push_str(&format!("\\u{:04X}", ch as u32));
            }
            ch => out.push(ch),
        }
    }
    out.push('"');
    out
}

impl Kind {
    /// Parses and validates a value written as a string — an environment
    /// variable, a command-line flag, or a server value, all of which arrive
    /// untyped.
    ///
    /// Returns the reason on rejection, phrased to be readable after "invalid
    /// value for `dispose_action`: ".
    ///
    /// # Errors
    ///
    /// If `raw` is not a value this kind accepts.
    pub fn parse(&self, raw: &str) -> Result<Value, String> {
        match self {
            Self::Choice(allowed) => {
                if allowed.contains(&raw) {
                    Ok(Value::Text(raw.to_owned()))
                } else {
                    Err(format!("must be one of {}", list_tokens(allowed)))
                }
            }
            Self::Text { .. } => self.coerce(Value::Text(raw.to_owned())),
            Self::Flag => match raw {
                "true" | "yes" | "on" | "1" => Ok(Value::Flag(true)),
                "false" | "no" | "off" | "0" => Ok(Value::Flag(false)),
                _ => Err("must be `true` or `false`".to_owned()),
            },
            Self::Number { .. } => {
                let number: i64 = raw
                    .trim()
                    .parse()
                    .map_err(|_| "must be a whole number".to_owned())?;
                let value = Value::Number(number);
                self.validate(&value)?;
                Ok(value)
            }
            Self::TokenList(_) => {
                let items: Vec<String> = raw
                    .split(',')
                    .map(str::trim)
                    .filter(|item| !item.is_empty())
                    .map(str::to_owned)
                    .collect();
                let value = Value::List(items);
                self.validate(&value)?;
                Ok(value)
            }
        }
    }

    /// Normalizes and validates an already-shaped value — the path a TOML file
    /// takes, where the document already carries a type and using it gives a
    /// better error than re-parsing a string would ("expected a boolean, found
    /// a string").
    ///
    /// # Errors
    ///
    /// If the value is the wrong shape for this kind, or out of range.
    pub fn coerce(&self, value: Value) -> Result<Value, String> {
        let value = self.normalize(value);
        self.validate(&value)?;
        Ok(value)
    }

    /// Trims single-line text.
    ///
    /// `_validate_name` in `lambda/api/set_preferences/function.py` strips the
    /// value before storing it, so a client that did not would show one thing
    /// and sync another. The signature is deliberately exempt: it is
    /// multi-line, the server does not strip it, and its RFC 3676 `"-- "`
    /// delimiter *ends in a significant space*.
    fn normalize(&self, value: Value) -> Value {
        match (self, value) {
            (
                Self::Text {
                    multiline: false, ..
                },
                Value::Text(text),
            ) => Value::Text(text.trim().to_owned()),
            (_, value) => value,
        }
    }

    /// Checks an already-shaped value without normalizing it.
    ///
    /// # Errors
    ///
    /// If the value is the wrong shape for this kind, or out of range.
    pub fn validate(&self, value: &Value) -> Result<(), String> {
        match (self, value) {
            (Self::Choice(allowed), Value::Text(text)) => {
                if allowed.contains(&text.as_str()) {
                    Ok(())
                } else {
                    Err(format!("must be one of {}", list_tokens(allowed)))
                }
            }
            (
                Self::Text {
                    max_chars,
                    multiline,
                },
                Value::Text(text),
            ) => validate_text(text, *max_chars, *multiline),
            (Self::Flag, Value::Flag(_)) => Ok(()),
            (Self::Number { min, max }, Value::Number(number)) => {
                if number < min || number > max {
                    Err(format!("must be between {min} and {max}"))
                } else {
                    Ok(())
                }
            }
            (Self::TokenList(allowed), Value::List(items)) => {
                for (index, item) in items.iter().enumerate() {
                    if !allowed.contains(&item.as_str()) {
                        return Err(format!("`{item}` is not one of {}", list_tokens(allowed)));
                    }
                    if items[..index].contains(item) {
                        return Err(format!("`{item}` is listed twice"));
                    }
                }
                Ok(())
            }
            (_, value) => Err(format!(
                "expected {}, found {}",
                self.expects(),
                value.type_name()
            )),
        }
    }

    /// The shape this kind wants, for a type-mismatch message.
    #[must_use]
    pub fn expects(&self) -> &'static str {
        match self {
            Self::Choice(_) | Self::Text { .. } => "a string",
            Self::Flag => "a boolean",
            Self::Number { .. } => "an integer",
            Self::TokenList(_) => "an array of strings",
        }
    }

    /// The accepted values, spelled out for the man page and the example file.
    #[must_use]
    pub fn describe(&self) -> String {
        match self {
            Self::Choice(allowed) => format!("one of {}", list_tokens(allowed)),
            Self::Text {
                max_chars,
                multiline: false,
            } => format!("text, up to {max_chars} characters"),
            Self::Text {
                max_chars,
                multiline: true,
            } => format!("text, up to {max_chars} characters, newlines allowed"),
            Self::Flag => "`true` or `false`".to_owned(),
            Self::Number { min, max } => format!("a whole number from {min} to {max}"),
            Self::TokenList(allowed) => format!("any of {}, in order", list_tokens(allowed)),
        }
    }
}

/// Text limits mirror the Lambda's validators exactly (`_validate_name` and
/// `_validate_signature` in `lambda/api/set_preferences/function.py`), so a
/// value the client accepts is a value the server accepts. Checking here is
/// what turns a rejected push into a message naming the line the user wrote.
fn validate_text(text: &str, max_chars: usize, multiline: bool) -> Result<(), String> {
    let length = text.chars().count();
    if length > max_chars {
        return Err(format!(
            "must be at most {max_chars} characters, but this is {length}"
        ));
    }
    for ch in text.chars() {
        let control = (ch as u32) < 0x20 || ch as u32 == 0x7f;
        if control && !(multiline && (ch == '\n' || ch == '\t')) {
            return Err(format!(
                "must not contain control characters, but this contains {}",
                ch.escape_debug()
            ));
        }
    }
    Ok(())
}

/// "`a`, `b`, or `c`" — the phrasing every "must be one of" message shares.
fn list_tokens(tokens: &[&str]) -> String {
    match tokens {
        [] => "nothing".to_owned(),
        [only] => format!("`{only}`"),
        [first, last] => format!("`{first}` or `{last}`"),
        [head @ .., last] => {
            let head: Vec<String> = head.iter().map(|token| format!("`{token}`")).collect();
            format!("{}, or `{last}`", head.join(", "))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::schema::Key;

    #[test]
    fn every_default_parses_and_validates_against_its_own_kind() {
        for key in Key::ALL.iter().copied() {
            let spec = key.spec();
            let value = spec
                .kind
                .parse(spec.default)
                .unwrap_or_else(|e| panic!("default for `{key}` is not valid: {e}"));
            spec.kind
                .validate(&value)
                .unwrap_or_else(|e| panic!("default for `{key}` does not validate: {e}"));
        }
    }

    #[test]
    fn choices_reject_anything_outside_the_set() {
        let kind = Kind::Choice(&["archive", "trash"]);
        assert_eq!(kind.parse("trash"), Ok(Value::Text("trash".to_owned())));
        assert_eq!(
            kind.parse("Trash").unwrap_err(),
            "must be one of `archive` or `trash`"
        );
    }

    #[test]
    fn flags_take_the_spellings_a_shell_user_expects() {
        for raw in ["true", "yes", "on", "1"] {
            assert_eq!(Kind::Flag.parse(raw), Ok(Value::Flag(true)), "{raw}");
        }
        for raw in ["false", "no", "off", "0"] {
            assert_eq!(Kind::Flag.parse(raw), Ok(Value::Flag(false)), "{raw}");
        }
        assert!(Kind::Flag.parse("maybe").is_err());
    }

    #[test]
    fn numbers_are_range_checked() {
        let kind = Kind::Number { min: 5, max: 10 };
        assert_eq!(kind.parse("7"), Ok(Value::Number(7)));
        assert_eq!(kind.parse("4").unwrap_err(), "must be between 5 and 10");
        assert_eq!(kind.parse("x").unwrap_err(), "must be a whole number");
    }

    #[test]
    fn token_lists_reject_unknown_and_repeated_tokens() {
        let kind = Kind::TokenList(&["open", "mark_read", "archive"]);
        assert_eq!(
            kind.parse("archive, open"),
            Ok(Value::List(vec!["archive".to_owned(), "open".to_owned()]))
        );
        assert_eq!(kind.parse(""), Ok(Value::List(Vec::new())));
        assert!(kind.parse("open, delete").unwrap_err().contains("`delete`"));
        assert!(kind.parse("open, open").unwrap_err().contains("twice"));
    }

    /// The display-name and signature caps are the Lambda's, and the split over
    /// which control characters are legal is the reason the two kinds differ.
    #[test]
    fn text_limits_mirror_the_lambda_validators() {
        let name = Kind::Text {
            max_chars: 100,
            multiline: false,
        };
        let signature = Kind::Text {
            max_chars: 2000,
            multiline: true,
        };

        assert!(name.parse(&"a".repeat(100)).is_ok());
        assert!(name.parse(&"a".repeat(101)).unwrap_err().contains("100"));
        assert!(name.parse("Jake\nCarr").is_err());
        assert!(
            signature
                .parse("-- \nsent from a machine I control")
                .is_ok()
        );
        assert!(signature.parse("tab\there").is_ok());
        assert!(signature.parse("bell\u{7}").is_err());
    }

    /// The Lambda stores the display name stripped, so a client that kept the
    /// surrounding whitespace would show one value and sync another. The
    /// signature is exempt, and has to be: its RFC 3676 delimiter is `"-- "`,
    /// trailing space included.
    #[test]
    fn single_line_text_is_trimmed_the_way_the_lambda_trims_it() {
        let name = Kind::Text {
            max_chars: 100,
            multiline: false,
        };
        assert_eq!(
            name.parse("  Jake Carr  "),
            Ok(Value::Text("Jake Carr".to_owned()))
        );

        let signature = Kind::Text {
            max_chars: 2000,
            multiline: true,
        };
        assert_eq!(
            signature.parse("-- \nsent\n"),
            Ok(Value::Text("-- \nsent\n".to_owned()))
        );
    }

    /// Character counts, not bytes — the Lambda's `len()` counts code points,
    /// so a byte-length check here would reject values the server accepts.
    #[test]
    fn text_length_counts_characters_not_bytes() {
        let kind = Kind::Text {
            max_chars: 4,
            multiline: false,
        };
        assert!(kind.parse("😀😀😀😀").is_ok());
        assert!(kind.parse("😀😀😀😀😀").is_err());
    }

    #[test]
    fn shape_mismatches_name_both_shapes() {
        let error = Kind::Flag
            .validate(&Value::Text("true".to_owned()))
            .unwrap_err();
        assert_eq!(error, "expected a boolean, found a string");
    }

    #[test]
    fn values_render_as_toml() {
        assert_eq!(Value::Flag(true).to_string(), "true");
        assert_eq!(Value::Number(200).to_string(), "200");
        assert_eq!(
            Value::Text("-- \nsent".to_owned()).to_string(),
            r#""-- \nsent""#
        );
        assert_eq!(
            Value::List(vec!["open".to_owned(), "archive".to_owned()]).to_string(),
            r#"["open", "archive"]"#
        );
    }
}

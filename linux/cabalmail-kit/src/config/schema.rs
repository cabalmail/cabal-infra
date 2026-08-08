//! The key table — the single source of truth for what is configurable.
//!
//! Everything else in `config` is driven by this table: the parser accepts a
//! key because it appears here, the file sections are a rendering of each
//! key's [`Scope`], `--print-config` iterates it, `config.example.toml` and the
//! `cabalmail.5` key list are generated from it, and Phase 6's push routing
//! reads [`Wire`] rather than a hand-maintained list someone can forget to
//! update. Adding a setting is a matter of adding a row.

use std::fmt;

/// How far a key's value is allowed to travel.
///
/// The distinguishing question for [`Scope::Linux`] is *"does this concept
/// exist on the other platforms?"* — not *"might the user want a different
/// value there?"*. A key that exists everywhere but that someone would like to
/// vary per machine is still [`Scope::Universal`]; conflating the two is how a
/// preference system ends up with an unsyncable everything.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum Scope {
    /// Synced to every device on every platform.
    Universal,
    /// Synced to this user's other Linux machines only.
    Linux,
    /// Never leaves this machine.
    Local,
}

impl Scope {
    /// Every scope, in the order the file renders them.
    pub const ALL: &'static [Scope] = &[Scope::Universal, Scope::Linux, Scope::Local];

    /// The `config.toml` section this scope is written in. The section is the
    /// file's *rendering* of the scope, which is why a key in the wrong one is
    /// an error rather than a silently accepted alias.
    #[must_use]
    pub const fn section(self) -> &'static str {
        match self {
            Self::Universal => "preferences",
            Self::Linux => "preferences.linux",
            Self::Local => "local",
        }
    }

    /// The scope a section name denotes, or `None` if no section is spelled
    /// that way.
    #[must_use]
    pub fn from_section(section: &str) -> Option<Self> {
        Self::ALL
            .iter()
            .copied()
            .find(|scope| scope.section() == section)
    }

    /// The sentence written above the section in `config.toml` and in the man
    /// page. Kept here so the file, the manual, and the Settings UI (Phase 6)
    /// describe a scope identically.
    #[must_use]
    pub const fn summary(self) -> &'static str {
        match self {
            Self::Universal => {
                "Synced across all your devices. Changing these here, in Settings, \
                 or on another device produces the same result."
            }
            Self::Linux => {
                "Synced to your other Linux machines only. Meaningless on iOS or the web."
            }
            Self::Local => "This machine only. Never leaves this device.",
        }
    }
}

impl fmt::Display for Scope {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.section())
    }
}

/// What a key accepts, and therefore how a file entry, an environment
/// variable, and a command-line flag are all validated.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    /// One token from a closed set.
    Choice(&'static [&'static str]),
    /// Free text, capped in characters. `multiline` permits `\n` and `\t`,
    /// matching the Lambda's signature validator; every other control
    /// character is rejected in both cases (a stored CR/LF in a header-bound
    /// value is a header-injection vector at send time).
    Text { max_chars: usize, multiline: bool },
    /// A boolean.
    Flag,
    /// An integer within an inclusive range.
    Number { min: i64, max: i64 },
    /// Zero or more distinct tokens from a closed set, order significant.
    TokenList(&'static [&'static str]),
}

/// Where a key goes when preferences are pushed to the server (Phase 6).
///
/// Nested per-platform maps are not expressible against `set_preferences`
/// (`_validate_app` tests `val not in APP_ALLOWED[key]`, and a dict value
/// raises `TypeError: unhashable type`), so platform-scoped keys ride as
/// prefixed scalars in the same `app` map.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Wire {
    /// A member of the request body's `app` map, under this name.
    App(&'static str),
    /// A top-level member of the request body, under this name. Only
    /// `name` — the display name shared with the React app.
    TopLevel(&'static str),
    /// Never sent. Every [`Scope::Local`] key.
    Never,
}

impl Wire {
    /// The name this key is sent under, if it is sent at all.
    #[must_use]
    pub const fn name(self) -> Option<&'static str> {
        match self {
            Self::App(name) | Self::TopLevel(name) => Some(name),
            Self::Never => None,
        }
    }
}

/// Whether a change takes effect immediately or on the next start.
///
/// Surfaced by `--print-config` and the man page so "why didn't that do
/// anything?" has an answer the user can read.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Reload {
    /// Applied as soon as the change is seen.
    Live,
    /// Read once at startup.
    Restart,
}

/// Everything static about one key.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct KeySpec {
    /// The key this describes.
    pub key: Key,
    /// The name as written in `config.toml`.
    pub name: &'static str,
    /// Where the value is allowed to travel, and therefore which section it
    /// is written in.
    pub scope: Scope,
    /// What the key accepts.
    pub kind: Kind,
    /// The built-in default, in the same syntax an environment variable uses.
    /// A test asserts every default parses and validates against its kind, so
    /// this cannot state something the parser would reject.
    pub default: &'static str,
    /// Where the key goes on a preferences push.
    pub wire: Wire,
    /// Whether a change applies live.
    pub reload: Reload,
    /// One or two sentences for the man page and `config.example.toml`.
    pub doc: &'static str,
}

impl KeySpec {
    /// The environment variable that overrides this key.
    #[must_use]
    pub fn env_var(&self) -> String {
        format!("CABALMAIL_{}", self.name.to_ascii_uppercase())
    }

    /// The command-line flag that overrides this key.
    #[must_use]
    pub fn flag(&self) -> String {
        format!("--{}", self.name.replace('_', "-"))
    }
}

macro_rules! keys {
    ($(
        $variant:ident = $name:literal {
            scope: $scope:ident,
            kind: $kind:expr,
            default: $default:literal,
            wire: $wire:expr,
            reload: $reload:ident,
            doc: $doc:literal,
        }
    )+) => {
        /// Every configuration key the client knows about.
        ///
        /// Declaration order is rendering order — for the file, the man page,
        /// and `--print-config` alike.
        #[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
        pub enum Key {
            $(#[doc = $doc] $variant,)+
        }

        impl Key {
            /// Every key, in declaration order.
            pub const ALL: &'static [Key] = &[$(Key::$variant,)+];

            /// This key's static description.
            #[must_use]
            pub fn spec(self) -> &'static KeySpec {
                match self {
                    $(Key::$variant => &KeySpec {
                        key: Key::$variant,
                        name: $name,
                        scope: Scope::$scope,
                        kind: $kind,
                        default: $default,
                        wire: $wire,
                        reload: Reload::$reload,
                        doc: $doc,
                    },)+
                }
            }
        }
    };
}

// The universal set is closed by the server: `set_preferences` rejects an
// unknown key in the `app` map with a 400 *by design*, so a key added here
// without the matching Lambda change would fail at runtime. The drift test in
// `xtask/tests/lambda_preferences_contract.rs` asserts the two lists — and the
// enums' value sets — are identical, so a divergence fails CI instead.
//
// `crash_reporting_enabled` is deliberately absent: it drives MetricKit, which
// has no Linux consumer. The Linux client never sends it, and the per-key merge
// in `set_preferences` means the iOS setting survives a Linux push untouched.
keys! {
    Name = "name" {
        scope: Universal,
        kind: Kind::Text { max_chars: 100, multiline: false },
        default: "",
        wire: Wire::TopLevel("name"),
        reload: Live,
        doc: "Display name used in the From header of messages you send. \
              Shared with the web client. Empty means no display name.",
    }

    MarkAsRead = "mark_as_read" {
        scope: Universal,
        kind: Kind::Choice(&["manual", "on_open"]),
        default: "manual",
        wire: Wire::App("mark_as_read"),
        reload: Live,
        doc: "When a message is marked read: `manual` only when you say so, \
              `on_open` as soon as the reader shows it.",
    }

    LoadRemoteContent = "load_remote_content" {
        scope: Universal,
        kind: Kind::Choice(&["off", "ask", "always"]),
        default: "off",
        wire: Wire::App("load_remote_content"),
        reload: Live,
        doc: "Whether the reader loads images and other resources hosted by \
              the sender. `off` blocks them, `ask` offers a per-message \
              banner, `always` loads them. Remote content is how a sender \
              learns you opened the message.",
    }

    DisposeAction = "dispose_action" {
        scope: Universal,
        kind: Kind::Choice(&["archive", "trash"]),
        default: "archive",
        wire: Wire::App("dispose_action"),
        reload: Live,
        doc: "Which folder the dispose action moves a message to.",
    }

    Theme = "theme" {
        scope: Universal,
        kind: Kind::Choice(&["system", "light", "dark"]),
        default: "system",
        wire: Wire::App("theme"),
        reload: Live,
        doc: "Light or dark appearance. `system` follows the desktop setting.",
    }

    DefaultBodyRenderMode = "default_body_render_mode" {
        scope: Universal,
        kind: Kind::Choice(&["original", "reader"]),
        default: "original",
        wire: Wire::App("default_body_render_mode"),
        reload: Live,
        doc: "How a message body is first rendered: `original` keeps the \
              sender's styling, `reader` applies a legible one.",
    }

    FolderCountDisplay = "folder_count_display" {
        scope: Universal,
        kind: Kind::Choice(&["unread", "total", "both"]),
        default: "unread",
        wire: Wire::App("folder_count_display"),
        reload: Live,
        doc: "Which count the folder sidebar shows next to each folder.",
    }

    DefaultFromAddress = "default_from_address" {
        scope: Universal,
        kind: Kind::Text { max_chars: 100, multiline: false },
        default: "",
        wire: Wire::App("default_from_address"),
        reload: Live,
        doc: "Address preselected when you compose. Empty means no default, \
              and a revoked address falls back to none.",
    }

    Signature = "signature" {
        scope: Universal,
        kind: Kind::Text { max_chars: 2000, multiline: true },
        default: "",
        wire: Wire::App("signature"),
        reload: Live,
        doc: "Plain-text signature appended to messages you send, below the \
              RFC 3676 `-- ` delimiter the composer inserts for you.",
    }

    // Platform-scoped. These sync to the user's other Linux machines under the
    // `linux_` prefix (Phase 6); the matching `APP_ALLOWED` additions ship as
    // their own PR against `lambda/api/`, so nothing pushes them yet.
    StartMinimized = "start_minimized" {
        scope: Linux,
        kind: Kind::Flag,
        default: "false",
        wire: Wire::App("linux_start_minimized"),
        reload: Restart,
        doc: "Start without showing a window, for keeping mail running in the \
              background.",
    }

    CloseToTray = "close_to_tray" {
        scope: Linux,
        kind: Kind::Flag,
        default: "false",
        wire: Wire::App("linux_close_to_tray"),
        reload: Live,
        doc: "Closing the window leaves the client running in the \
              notification area instead of quitting. Requires a \
              StatusNotifierItem host, which stock GNOME does not provide \
              without the AppIndicator extension; where it is unavailable the \
              setting is kept but not honoured.",
    }

    SingleInstance = "single_instance" {
        scope: Linux,
        kind: Kind::Flag,
        default: "true",
        wire: Wire::App("linux_single_instance"),
        reload: Restart,
        doc: "A second launch raises the running window instead of starting a \
              second copy.",
    }

    NotificationActions = "notification_actions" {
        scope: Linux,
        kind: Kind::TokenList(&["open", "mark_read", "archive"]),
        default: "open,mark_read,archive",
        wire: Wire::App("linux_notification_actions"),
        reload: Live,
        doc: "Buttons offered on a new-mail notification, in order. An empty \
              list shows the notification with no actions.",
    }

    // Machine-local. Syncing any of these would be actively wrong: they name
    // this box's deployment, paths, and daemons.
    ControlDomain = "control_domain" {
        scope: Local,
        kind: Kind::Text { max_chars: 253, multiline: false },
        default: "",
        wire: Wire::Never,
        reload: Restart,
        doc: "The Cabalmail deployment this machine talks to — the host that \
              serves `config.json`. Set it to pin a workstation to stage; \
              empty means the client asks on first launch.",
    }

    Username = "username" {
        scope: Local,
        kind: Kind::Text { max_chars: 128, multiline: false },
        default: "",
        wire: Wire::Never,
        reload: Restart,
        doc: "Account prefilled on the sign-in screen. Credentials themselves \
              are never stored here — they live in the Secret Service \
              keyring.",
    }

    LogLevel = "log_level" {
        scope: Local,
        kind: Kind::Choice(&["error", "warn", "info", "debug", "trace"]),
        default: "info",
        wire: Wire::Never,
        reload: Live,
        doc: "Verbosity of the debug log.",
    }

    CacheMaxMb = "cache_max_mb" {
        scope: Local,
        kind: Kind::Number { min: 1, max: 1_000_000 },
        default: "200",
        wire: Wire::Never,
        reload: Live,
        doc: "Cap on the cached message bodies, in megabytes. The oldest are \
              evicted past it; the cache is safe to delete at any time.",
    }

    CacheDir = "cache_dir" {
        scope: Local,
        kind: Kind::Text { max_chars: 4096, multiline: false },
        default: "",
        wire: Wire::Never,
        reload: Restart,
        doc: "Overrides where cached envelopes and bodies are written. Empty \
              uses the XDG cache directory.",
    }

    PollIntervalSeconds = "poll_interval_seconds" {
        scope: Local,
        kind: Kind::Number { min: 5, max: 3600 },
        default: "60",
        wire: Wire::Never,
        reload: Live,
        doc: "How often folders are checked for new mail while the window has \
              focus. There is no push channel on Linux, so this is what \
              decides how quickly new mail appears.",
    }

    PollIntervalUnfocusedSeconds = "poll_interval_unfocused_seconds" {
        scope: Local,
        kind: Kind::Number { min: 30, max: 86_400 },
        default: "300",
        wire: Wire::Never,
        reload: Live,
        doc: "The same, while the window is unfocused or the machine is on \
              battery.",
    }

    Proxy = "proxy" {
        scope: Local,
        kind: Kind::Text { max_chars: 2048, multiline: false },
        default: "",
        wire: Wire::Never,
        reload: Restart,
        doc: "HTTP proxy for API requests, as a URL. Empty uses the \
              environment's proxy settings.",
    }

    Keyring = "keyring" {
        scope: Local,
        kind: Kind::Choice(&["auto", "secret-service", "none"]),
        default: "auto",
        wire: Wire::Never,
        reload: Restart,
        doc: "Where credentials are kept. `secret-service` requires a running \
              keyring daemon; `none` keeps them in memory for the session \
              only, so you sign in again next launch. `auto` uses the Secret \
              Service when one answers.",
    }

    SessionOnly = "session_only" {
        scope: Local,
        kind: Kind::Flag,
        default: "false",
        wire: Wire::Never,
        reload: Restart,
        doc: "Never write credentials to the keyring, even when one is \
              available. Equivalent to `keyring = \"none\"`, and the same as \
              passing `--session-only`.",
    }
}

impl Key {
    /// The key with this `config.toml` name, in any section.
    ///
    /// Deliberately not section-scoped: the parser looks a name up globally so
    /// it can tell "no such key" from "right key, wrong section" and say which
    /// it is.
    #[must_use]
    pub fn from_name(name: &str) -> Option<Self> {
        Self::ALL.iter().copied().find(|key| key.name() == name)
    }

    /// The key overridden by this environment variable.
    #[must_use]
    pub fn from_env_var(var: &str) -> Option<Self> {
        Self::ALL
            .iter()
            .copied()
            .find(|key| key.spec().env_var() == var)
    }

    /// The key overridden by this command-line flag (`--dispose-action`).
    #[must_use]
    pub fn from_flag(flag: &str) -> Option<Self> {
        Self::ALL
            .iter()
            .copied()
            .find(|key| key.spec().flag() == flag)
    }

    /// The name as written in `config.toml`.
    #[must_use]
    pub fn name(self) -> &'static str {
        self.spec().name
    }

    /// Where this key's value is allowed to travel.
    #[must_use]
    pub fn scope(self) -> Scope {
        self.spec().scope
    }

    /// What this key accepts.
    #[must_use]
    pub fn kind(self) -> Kind {
        self.spec().kind
    }

    /// The `[section].key` spelling used in errors and `--print-config`.
    #[must_use]
    pub fn qualified_name(self) -> String {
        format!("{}.{}", self.scope().section(), self.name())
    }

    /// Every key in one scope, in declaration order.
    pub fn in_scope(scope: Scope) -> impl Iterator<Item = Self> {
        Self::ALL
            .iter()
            .copied()
            .filter(move |key| key.scope() == scope)
    }
}

impl fmt::Display for Key {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.name())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::BTreeSet;

    /// `Settings` indexes its values by `key as usize`, which is only sound if
    /// the discriminants line up with positions in `ALL`.
    #[test]
    fn discriminants_match_positions_in_all() {
        for (index, key) in Key::ALL.iter().enumerate() {
            assert_eq!(*key as usize, index, "{key} is out of order in ALL");
        }
    }

    #[test]
    fn names_are_unique() {
        let mut seen = BTreeSet::new();
        for key in Key::ALL {
            assert!(seen.insert(key.name()), "duplicate key name `{key}`");
        }
    }

    /// Environment variables and flags are derived from the name by a
    /// mechanical transform, so a name collision would silently shadow a key.
    #[test]
    fn derived_env_vars_and_flags_are_unique() {
        let mut vars = BTreeSet::new();
        let mut flags = BTreeSet::new();
        for key in Key::ALL {
            assert!(
                vars.insert(key.spec().env_var()),
                "duplicate environment variable for `{key}`"
            );
            assert!(
                flags.insert(key.spec().flag()),
                "duplicate flag for `{key}`"
            );
        }
    }

    #[test]
    fn every_key_is_reachable_by_name_env_var_and_flag() {
        for key in Key::ALL.iter().copied() {
            assert_eq!(Key::from_name(key.name()), Some(key));
            assert_eq!(Key::from_env_var(&key.spec().env_var()), Some(key));
            assert_eq!(Key::from_flag(&key.spec().flag()), Some(key));
        }
        assert_eq!(Key::from_name("no_such_key"), None);
        assert_eq!(Key::from_flag("--no-such-key"), None);
    }

    /// Wire names are the routing Phase 6 pushes on. The convention — universal
    /// keys as themselves, platform-scoped keys under `linux_`, machine-local
    /// keys never — has to hold for every key, not just the ones someone
    /// remembered.
    #[test]
    fn wire_names_follow_the_scope_convention() {
        for key in Key::ALL.iter().copied() {
            match key.scope() {
                Scope::Universal => {
                    let name = key.spec().wire.name().unwrap_or_else(|| {
                        panic!("universal key `{key}` is never sent to the server")
                    });
                    assert_eq!(
                        name,
                        key.name(),
                        "universal key `{key}` renames on the wire"
                    );
                }
                Scope::Linux => {
                    let name = key
                        .spec()
                        .wire
                        .name()
                        .unwrap_or_else(|| panic!("platform-scoped key `{key}` is never sent"));
                    assert_eq!(
                        name,
                        format!("linux_{}", key.name()),
                        "platform-scoped key `{key}` is not `linux_`-prefixed"
                    );
                    assert!(
                        matches!(key.spec().wire, Wire::App(_)),
                        "platform-scoped key `{key}` must ride in the `app` map"
                    );
                }
                Scope::Local => assert_eq!(
                    key.spec().wire,
                    Wire::Never,
                    "machine-local key `{key}` would be sent to the server"
                ),
            }
        }
    }

    /// `name` is the one universal key that is not a member of the `app` map —
    /// it is the top-level display name the React app also writes.
    #[test]
    fn only_the_display_name_rides_at_the_top_level() {
        let top_level: Vec<Key> = Key::ALL
            .iter()
            .copied()
            .filter(|key| matches!(key.spec().wire, Wire::TopLevel(_)))
            .collect();
        assert_eq!(top_level, vec![Key::Name]);
    }

    #[test]
    fn sections_round_trip_through_scopes() {
        for scope in Scope::ALL.iter().copied() {
            assert_eq!(Scope::from_section(scope.section()), Some(scope));
        }
        assert_eq!(Scope::from_section("preference"), None);
    }

    #[test]
    fn every_scope_has_at_least_one_key() {
        for scope in Scope::ALL.iter().copied() {
            assert!(
                Key::in_scope(scope).next().is_some(),
                "no keys declared in [{scope}]"
            );
        }
    }

    /// A doc string that says nothing is a man page entry that says nothing.
    #[test]
    fn every_key_documents_itself() {
        for key in Key::ALL.iter().copied() {
            let doc = key.spec().doc;
            assert!(doc.len() > 20, "`{key}` has no useful documentation");
            assert!(
                doc.ends_with('.'),
                "`{key}`'s documentation is not a sentence"
            );
        }
    }
}

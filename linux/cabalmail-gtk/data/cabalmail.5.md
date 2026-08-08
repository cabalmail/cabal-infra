% CABALMAIL(5) | File Formats Manual

# NAME

cabalmail - configuration file for the Cabalmail desktop client

# SYNOPSIS

`$XDG_CONFIG_HOME/cabalmail/config.toml`  (usually `~/.config/cabalmail/config.toml`)

`$XDG_CONFIG_DIRS/cabalmail/config.toml`  (usually `/etc/xdg/cabalmail/config.toml`)

# DESCRIPTION

Cabalmail reads a TOML configuration file. It is meant to be edited: open it in
an editor, save it, and the running client picks the change up.

The file is **not** an override layer that switches synced preferences off. It
is a peer editor - a second way into the same store the Settings window writes
to, and a materialized view of that store's synced sections. Changing
`dispose_action` in an editor does exactly what changing it in Settings does:
the value lands in the store and is pushed to the server on the same debounce,
so it reaches your other devices. A change made on another device is written
back into this file.

Client writes are atomic - a temporary file and `rename(2)` - and preserve your
comments, key order, and spacing. Only the values that changed are touched.

The client materializes the file on first sign-in, so there is something to
read before there is something to edit. A commented reference copy is installed
to `/usr/share/doc/cabalmail/config.example.toml`.

# FILES

| Path | Contents |
| --- | --- |
| `$XDG_CONFIG_HOME/cabalmail/config.toml` | Your settings. |
| `$XDG_CONFIG_DIRS/cabalmail/config.toml` | Site and distribution defaults, in `$XDG_CONFIG_DIRS` order. Not shipped by any Cabalmail package - a file there is one an administrator put there. |
| `$XDG_STATE_HOME/cabalmail/` | Window geometry, pane positions, the expanded-folder set, logs. State, not configuration; nobody hand-edits a window size. |
| `$XDG_DATA_HOME/cabalmail/` | Drafts and the outbox. User data; survives a cache wipe. |
| `$XDG_CACHE_HOME/cabalmail/` | Cached envelopes, message bodies, and the fetched deployment descriptor. Safe to delete at any time. |

Credentials are never in a file. They live in the Secret Service keyring
(gnome-keyring, KWallet, KeePassXC); see the `keyring` and `session_only`
settings.

# PRECEDENCE

Highest wins:

1. Command-line options (`--dispose-action trash`)
2. Environment variables (`CABALMAIL_DISPOSE_ACTION=trash`)
3. `$XDG_CONFIG_HOME/cabalmail/config.toml`
4. Each entry of `$XDG_CONFIG_DIRS`, in order
5. Preferences synced from the server
6. Built-in defaults

Options and environment variables are **transient local overrides**: they apply
for one run, are never written into the file, and are never pushed to the
server.

`cabalmail --print-config` prints every setting, the value in force, and which
of these it came from. Settings that only take effect on the next start are
marked there and noted below.

# SYNC SCOPES

Each setting belongs to exactly one section, and the section says how far its
value travels. A setting written in the wrong section is an error naming the
section it belongs in - not a silently ignored line.

| Section | Reaches |
| --- | --- |
| `[preferences]` | Every device you use, on every platform - this client, the Apple clients, the web app. |
| `[preferences.linux]` | Your other Linux machines only. These describe things that do not exist on the other platforms. |
| `[local]` | Nothing. They describe this machine: which deployment it talks to, where its caches live, which keyring it uses. |

The question that decides the second scope is *does this concept exist on the
other platforms*, not *might I want a different value there*. A setting that
exists everywhere but that you would like to vary per machine is still
universal.

Deleting a line does not reset a setting. A missing key means "no local
opinion": the store keeps its value and the line reappears on the next rewrite.
To reset one, run `cabalmail config reset <setting>`, which writes the default
explicitly and propagates it.

# KEYS

<!-- BEGIN GENERATED KEYS -->

### `[preferences]`

Synced across all your devices. Changing these here, in Settings, or on another device produces the same result.

#### `name`

Display name used in the From header of messages you send. Shared with the web client. Empty means no display name.

*Accepts:* text, up to 100 characters.  
*Default:* `""`.  
*Environment:* `CABALMAIL_NAME`. *Option:* `--name`.  
*Applies:* immediately.  
*Syncs:* to every device you use, on every platform.

#### `mark_as_read`

When a message is marked read: `manual` only when you say so, `on_open` as soon as the reader shows it.

*Accepts:* one of `manual` or `on_open`.  
*Default:* `"manual"`.  
*Environment:* `CABALMAIL_MARK_AS_READ`. *Option:* `--mark-as-read`.  
*Applies:* immediately.  
*Syncs:* to every device you use, on every platform.

#### `load_remote_content`

Whether the reader loads images and other resources hosted by the sender. `off` blocks them, `ask` offers a per-message banner, `always` loads them. Remote content is how a sender learns you opened the message.

*Accepts:* one of `off`, `ask`, or `always`.  
*Default:* `"off"`.  
*Environment:* `CABALMAIL_LOAD_REMOTE_CONTENT`. *Option:* `--load-remote-content`.  
*Applies:* immediately.  
*Syncs:* to every device you use, on every platform.

#### `dispose_action`

Which folder the dispose action moves a message to.

*Accepts:* one of `archive` or `trash`.  
*Default:* `"archive"`.  
*Environment:* `CABALMAIL_DISPOSE_ACTION`. *Option:* `--dispose-action`.  
*Applies:* immediately.  
*Syncs:* to every device you use, on every platform.

#### `theme`

Light or dark appearance. `system` follows the desktop setting.

*Accepts:* one of `system`, `light`, or `dark`.  
*Default:* `"system"`.  
*Environment:* `CABALMAIL_THEME`. *Option:* `--theme`.  
*Applies:* immediately.  
*Syncs:* to every device you use, on every platform.

#### `default_body_render_mode`

How a message body is first rendered: `original` keeps the sender's styling, `reader` applies a legible one.

*Accepts:* one of `original` or `reader`.  
*Default:* `"original"`.  
*Environment:* `CABALMAIL_DEFAULT_BODY_RENDER_MODE`. *Option:* `--default-body-render-mode`.  
*Applies:* immediately.  
*Syncs:* to every device you use, on every platform.

#### `folder_count_display`

Which count the folder sidebar shows next to each folder.

*Accepts:* one of `unread`, `total`, or `both`.  
*Default:* `"unread"`.  
*Environment:* `CABALMAIL_FOLDER_COUNT_DISPLAY`. *Option:* `--folder-count-display`.  
*Applies:* immediately.  
*Syncs:* to every device you use, on every platform.

#### `default_from_address`

Address preselected when you compose. Empty means no default, and a revoked address falls back to none.

*Accepts:* text, up to 100 characters.  
*Default:* `""`.  
*Environment:* `CABALMAIL_DEFAULT_FROM_ADDRESS`. *Option:* `--default-from-address`.  
*Applies:* immediately.  
*Syncs:* to every device you use, on every platform.

#### `signature`

Plain-text signature appended to messages you send, below the RFC 3676 `-- ` delimiter the composer inserts for you.

*Accepts:* text, up to 2000 characters, newlines allowed.  
*Default:* `""`.  
*Environment:* `CABALMAIL_SIGNATURE`. *Option:* `--signature`.  
*Applies:* immediately.  
*Syncs:* to every device you use, on every platform.

### `[preferences.linux]`

Synced to your other Linux machines only. Meaningless on iOS or the web.

#### `start_minimized`

Start without showing a window, for keeping mail running in the background.

*Accepts:* `true` or `false`.  
*Default:* `false`.  
*Environment:* `CABALMAIL_START_MINIMIZED`. *Option:* `--start-minimized`.  
*Applies:* on the next start.  
*Syncs:* to your other Linux machines only.

#### `close_to_tray`

Closing the window leaves the client running in the notification area instead of quitting. Requires a StatusNotifierItem host, which stock GNOME does not provide without the AppIndicator extension; where it is unavailable the setting is kept but not honoured.

*Accepts:* `true` or `false`.  
*Default:* `false`.  
*Environment:* `CABALMAIL_CLOSE_TO_TRAY`. *Option:* `--close-to-tray`.  
*Applies:* immediately.  
*Syncs:* to your other Linux machines only.

#### `single_instance`

A second launch raises the running window instead of starting a second copy.

*Accepts:* `true` or `false`.  
*Default:* `true`.  
*Environment:* `CABALMAIL_SINGLE_INSTANCE`. *Option:* `--single-instance`.  
*Applies:* on the next start.  
*Syncs:* to your other Linux machines only.

#### `notification_actions`

Buttons offered on a new-mail notification, in order. An empty list shows the notification with no actions.

*Accepts:* any of `open`, `mark_read`, or `archive`, in order.  
*Default:* `["open", "mark_read", "archive"]`.  
*Environment:* `CABALMAIL_NOTIFICATION_ACTIONS`. *Option:* `--notification-actions`.  
*Applies:* immediately.  
*Syncs:* to your other Linux machines only.

### `[local]`

This machine only. Never leaves this device.

#### `control_domain`

The Cabalmail deployment this machine talks to — the host that serves `config.json`. Set it to pin a workstation to stage; empty means the client asks on first launch.

*Accepts:* text, up to 253 characters.  
*Default:* `""`.  
*Environment:* `CABALMAIL_CONTROL_DOMAIN`. *Option:* `--control-domain`.  
*Applies:* on the next start.  
*Syncs:* never — this machine only.

#### `username`

Account prefilled on the sign-in screen. Credentials themselves are never stored here — they live in the Secret Service keyring.

*Accepts:* text, up to 128 characters.  
*Default:* `""`.  
*Environment:* `CABALMAIL_USERNAME`. *Option:* `--username`.  
*Applies:* on the next start.  
*Syncs:* never — this machine only.

#### `log_level`

Verbosity of the debug log.

*Accepts:* one of `error`, `warn`, `info`, `debug`, or `trace`.  
*Default:* `"info"`.  
*Environment:* `CABALMAIL_LOG_LEVEL`. *Option:* `--log-level`.  
*Applies:* immediately.  
*Syncs:* never — this machine only.

#### `cache_max_mb`

Cap on the cached message bodies, in megabytes. The oldest are evicted past it; the cache is safe to delete at any time.

*Accepts:* a whole number from 1 to 1000000.  
*Default:* `200`.  
*Environment:* `CABALMAIL_CACHE_MAX_MB`. *Option:* `--cache-max-mb`.  
*Applies:* immediately.  
*Syncs:* never — this machine only.

#### `cache_dir`

Overrides where cached envelopes and bodies are written. Empty uses the XDG cache directory.

*Accepts:* text, up to 4096 characters.  
*Default:* `""`.  
*Environment:* `CABALMAIL_CACHE_DIR`. *Option:* `--cache-dir`.  
*Applies:* on the next start.  
*Syncs:* never — this machine only.

#### `poll_interval_seconds`

How often folders are checked for new mail while the window has focus. There is no push channel on Linux, so this is what decides how quickly new mail appears.

*Accepts:* a whole number from 5 to 3600.  
*Default:* `60`.  
*Environment:* `CABALMAIL_POLL_INTERVAL_SECONDS`. *Option:* `--poll-interval-seconds`.  
*Applies:* immediately.  
*Syncs:* never — this machine only.

#### `poll_interval_unfocused_seconds`

The same, while the window is unfocused or the machine is on battery.

*Accepts:* a whole number from 30 to 86400.  
*Default:* `300`.  
*Environment:* `CABALMAIL_POLL_INTERVAL_UNFOCUSED_SECONDS`. *Option:* `--poll-interval-unfocused-seconds`.  
*Applies:* immediately.  
*Syncs:* never — this machine only.

#### `proxy`

HTTP proxy for API requests, as a URL. Empty uses the environment's proxy settings.

*Accepts:* text, up to 2048 characters.  
*Default:* `""`.  
*Environment:* `CABALMAIL_PROXY`. *Option:* `--proxy`.  
*Applies:* on the next start.  
*Syncs:* never — this machine only.

#### `keyring`

Where credentials are kept. `secret-service` requires a running keyring daemon; `none` keeps them in memory for the session only, so you sign in again next launch. `auto` uses the Secret Service when one answers.

*Accepts:* one of `auto`, `secret-service`, or `none`.  
*Default:* `"auto"`.  
*Environment:* `CABALMAIL_KEYRING`. *Option:* `--keyring`.  
*Applies:* on the next start.  
*Syncs:* never — this machine only.

#### `session_only`

Never write credentials to the keyring, even when one is available. Equivalent to `keyring = "none"`, and the same as passing `--session-only`.

*Accepts:* `true` or `false`.  
*Default:* `false`.  
*Environment:* `CABALMAIL_SESSION_ONLY`. *Option:* `--session-only`.  
*Applies:* on the next start.  
*Syncs:* never — this machine only.

<!-- END GENERATED KEYS -->

# ENVIRONMENT

`CABALMAIL_*`
: Every setting has one, named for the setting in upper case - `signature` is
  `CABALMAIL_SIGNATURE`. An unrecognised `CABALMAIL_*` variable is reported and
  ignored rather than fatal; a bad *value* is fatal, because it was meant.

`XDG_CONFIG_HOME`, `XDG_CONFIG_DIRS`, `XDG_STATE_HOME`, `XDG_DATA_HOME`, `XDG_CACHE_HOME`
: Standard XDG base directories, honoured as specified. Relative paths in them
  are ignored.

# EXAMPLES

A minimal file pinning a workstation to a staging deployment while leaving
everything else to sync:

```toml
[local]
control_domain = "stage.cabalmail.example"
log_level      = "debug"
```

Setting one value without opening an editor:

```sh
cabalmail config set dispose_action trash
cabalmail config reset dispose_action
```

Overriding a setting for one run, without changing the file or the server:

```sh
CABALMAIL_LOG_LEVEL=trace cabalmail
cabalmail --session-only
```

# NOTES

A syntax error, an unknown setting, a setting in the wrong section, or a value
outside what a setting accepts stops the client with the file, line, column,
and the offending key. It never falls back to defaults - a client that started
with defaults would be indistinguishable from one that ignored your file.

While the client is running, a save that does not parse leaves the last good
values in force, reports the position of the problem, and pushes nothing to the
server. A half-saved file never reaches your other devices.

Synced settings carry no timestamp on the server, so the client cannot tell
which of two edits is newer. Editing this file on a disconnected machine while
another device changes the same setting is resolved by the next pull, which
wins. This is bounded and rare, but it is real.

# SEE ALSO

`cabalmail(1)`

Cabalmail: <https://github.com/cabalmail/cabal-infra>

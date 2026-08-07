# Native Linux Client Plan

## Context

The React admin app (`react/admin/`) and the native Apple clients (`apple/`) currently serve as the Cabalmail clients. Version 1.1.0 adds two native clients alongside the existing pair: the Android client (see [`android-client-plan.md`](android-client-plan.md)) and the Linux desktop client described here. The two are independent efforts that share this version slot, a set of guiding principles, and the Lambda API contract — nothing else.

The Linux client mirrors the *user-facing* portions of the Apple client: mail reading, composition and send, folder management, address creation / revocation / suspension, on-the-fly `From` addresses, cross-device drafts, search, and synced preferences. Administrative functionality (user management, DMARC reports, multi-user address assignment, domain access grants) is out of scope; admins continue to use the web app.

Scope of "Linux client" for 1.1.0:

- **Arch Linux** is the first packaging target, delivered as a `PKGBUILD` suitable for the AUR.
- **Debian / Ubuntu** (`.deb`) and **RHEL-family** (`.rpm`) follow in Phase 8, built by the same CI matrix.
- **GNOME is the reference desktop.** The app is built on GTK4 + libadwaita and will look and behave correctly on KDE, Xfce, and tiling WMs, but GNOME HIG is the design authority when conventions conflict.
- **Wayland is the primary session**, X11 supported via GDK's X11 backend for as long as GTK ships it.

Distribution through official distro repositories is explicitly *not* a 1.1.x goal. This phase produces a client that is continuously built, tested, and packaged in CI, installable from a CI artifact or the AUR.

---

## Approach

Eight phases: workspace scaffolding; **build pipeline, packaging, and test harness (early, so every subsequent phase ships through it)**; configuration / auth / API transport; mail reading; composition and on-the-fly `From`; address, folder, and settings management; desktop integration and polish; then Debian and RHEL packaging.

### Guiding principles

- **API-backed, always.** The client speaks only to the existing Lambda surface (34 endpoints, enumerated in Phase 3). No IMAP library, no SMTP transport, no MIME transmit path, no IDLE plumbing. This is not a simplification of the Apple design — it *is* the Apple design as shipped (`ApiBackedImapClient`, issue #371). The hand-rolled IMAP detour is not repeated.
- **Native idioms over pixel parity.** Where the Apple client uses a SwiftUI control, the Linux client uses the libadwaita equivalent: `AdwNavigationSplitView`, `AdwToolbarView`, `AdwPreferencesPage`, `AdwToastOverlay`, `AdwAlertDialog`, `GtkListView`. The goal is an app that sits comfortably next to Geary and Evolution, not a transliteration of the iOS UI.
- **The kit has no GUI dependency.** `cabalmail-kit` compiles and tests without GTK, WebKit, or a display server. This is what lets the bulk of the test suite run on a bare `ubuntu-latest` runner in seconds, and it is the single most important structural decision in this plan.
- **No new Lambdas required.** The existing API surface covers every operation the client needs. The one genuine gap — push — is handled by polling (see Phase 7).
- **No code sharing with Apple, Android, or web.** Rust types are defined fresh. Sharing is limited to the *contract* (endpoint paths and JSON shapes) and to the composer's vendored JS, which is already shared between React and Apple.
- **Build the oldest supported target first.** Ubuntu 24.04 LTS pins the API floor at GTK 4.14 / libadwaita 1.4. Developing on Arch's GTK 4.22 / libadwaita 1.9 and discovering the floor at packaging time is the predictable failure mode; the CI matrix builds against the floor from Phase 2 onward.

### Lessons carried forward

| Apple / Android plan said | What actually shipped, or what we now know | Linux implication |
|---|---|---|
| Direct IMAP/SMTP as primary transport | `ApiBackedImapClient` via the Lambda API | API-backed from commit one; no IMAP spike |
| IDLE for foreground push | Polling — no IDLE over the API | Poll `/folder_status`; adaptive interval |
| APNs push with an on-device NSE | APNs-only: `push_register` validates a 64-hex APNs device token, `push_dispatch` fans out to APNs | **Push is unavailable to Linux.** Poll + desktop notifications; Web Push is a documented seam, not 1.1.0 scope |
| Local-only drafts | Cross-device sync via `/save_draft`, Markdown-canonical bodies | Same — Markdown-canonical compose, server draft sync |
| Native rich-text widget | WKWebView contenteditable + marked/turndown from `react/admin/node_modules` | Reuse the *same* `editor.html` + `editor-bridge.js` + marked/turndown inside WebKitGTK |
| Prefs stored locally | Synced via `/get_preferences` / `/set_preferences` under an `app` map | Same wire keys, same server-wins-on-login semantics |
| Search as an afterthought | Cross-folder structured search (`/search_envelopes`) + filter sheet + All/Unread/Flagged pills | First-class scope from Phase 4 |
| No cross-device resume | Nav-state cursor (`/get_nav_state` / `/set_nav_state`) with a restore prompt | Same |
| Keychain for secrets | Data-protection keychain | Secret Service (`oo7`), with an explicit failure mode when no keyring daemon is running |
| App-layer UI logic tested ad hoc | 24 test files in `apple/CabalmailTests/` pinning *pure* policy types (`CompactColumnPolicy`, `ReaderToolbarLayout`, `MessageRowIdentity`, `ComposeCancelPolicy`, …) | Treat that file list as the specification for which UI decisions to extract as pure functions in `cabalmail-kit` |

### Stack decisions

| Choice | Decision | Rationale |
|---|---|---|
| Language | **Rust** (2021 edition), MSRV pinned to Debian stable's rustc | One binary, no runtime to package, strong test story |
| UI toolkit | **GTK4 + libadwaita** via `gtk4-rs` / `libadwaita-rs` | The native Linux desktop default; adaptive layout primitives are the `sidebarAdaptable` analog |
| API floor | **GTK 4.14 / libadwaita 1.4** | Ubuntu 24.04 LTS. Rules out `AdwBottomSheet`, `AdwSpinner`, and other 1.5+/4.16+ API |
| HTML rendering | **WebKitGTK 6.0** (`webkit6` crate) | Direct WKWebView analog; renders mail bodies *and* hosts the composer |
| HTTP | **`reqwest`** (rustls, no OpenSSL link) + **`tokio`** | rustls keeps the dependency surface identical across all three distros |
| JSON | **`serde` / `serde_json`** | Standard |
| Auth | **Hand-rolled Cognito `USER_PASSWORD_AUTH`** | Exactly what `CognitoAuthService` does — JSON POSTs to `cognito-idp.<region>.amazonaws.com`. No AWS SDK |
| Secret storage | **`oo7`** (pure-Rust Secret Service client) | Keychain analog; async, GNOME-blessed, works with gnome-keyring and KWallet's SS interface |
| User config | **Hand-editable TOML** at `$XDG_CONFIG_HOME/cabalmail/config.toml` | Linux users expect to edit a text file; see Configuration model below |
| Local state | **`directories`** for XDG base dirs + JSON files | Mirrors the Apple on-disk Codable mirrors; no database, no dconf |
| UI definition | **Blueprint** (`.blp`) compiled to `.ui` | Readable diffs; falls back to plain `.ui` XML if `blueprint-compiler` proves awkward to package |
| Async bridging | **One `tokio` multi-thread runtime + `async-channel` into `glib::spawn_future_local`** | See below — this is the one genuinely hard structural problem |
| Testing | **`cargo test`** + **`wiremock`** (HTTP contract) + **`xvfb`** for widget tests | Kit tests need no display; app tests need a headless one |
| Linting | **`rustfmt` + `clippy -D warnings`**, plus **`namcap`** / **`lintian`** / **`rpmlint`** on packages | Mirrors swiftlint's role in `apple.yml` |
| Task automation | **`cargo xtask`** | Gives AI-executed phases one deterministic entry point per operation |

#### Async bridging: the one structural risk

GTK owns the main thread and its own `glib::MainContext` event loop; `reqwest` wants a `tokio` reactor. Getting this wrong produces an app that deadlocks under load or blocks the UI on every request, and it is very hard to retrofit. The pattern is fixed in Phase 1 and every later phase follows it:

- The app owns exactly one `tokio::runtime::Runtime` (multi-thread), created at startup and stored in the application struct.
- Every `cabalmail-kit` call is `runtime.spawn(...)`ed. Kit futures are `Send` and never touch GTK types — enforced structurally, since the kit crate has no GTK dependency to touch.
- Results return to the UI over an `async_channel::Sender`, consumed by a `glib::spawn_future_local` task that owns the widget handles.
- Widgets are never captured across an `.await` that crosses the runtime boundary. `glib::clone!(#[weak] ...)` is the standard capture form.

`cabalmail-gtk` gets a single `spawn_to_ui!` helper wrapping this dance, written and tested in Phase 1 before any feature code exists.

### Configuration model

The Apple client has no user-editable configuration: settings are server-synced and everything else is `UserDefaults`. Porting that model directly would give Linux users nothing to edit, which is wrong for the platform — a hand-editable file under `$XDG_CONFIG_HOME` is a baseline expectation, and "I can grep and diff my config" is a real reason people choose a native client over the web app.

But a hand-edited file has to coexist with server-synced preferences. If a user sets `dispose_action = "trash"` in a file and the next login pulls `"archive"` from the server, their edit is silently reverted — worse than having no file at all. The resolution is explicit precedence plus **treating the file as a peer editor that participates in sync**, rather than as an override layer that suppresses it.

#### Precedence, highest wins

1. Command-line flags
2. Environment variables (`CABALMAIL_*`, e.g. `CABALMAIL_LOG_LEVEL`)
3. `$XDG_CONFIG_HOME/cabalmail/config.toml` (default `~/.config/cabalmail/config.toml`)
4. Each entry of `$XDG_CONFIG_DIRS` in order (default `/etc/xdg/cabalmail/config.toml`) — gives distro and site administrators a defaults drop point
5. Server-synced preferences (`/get_preferences`)
6. Built-in defaults

Note the spec variables are `XDG_CONFIG_HOME` (a single directory) and `XDG_CONFIG_DIRS` (a colon-separated system list). Use the `directories` crate for the former and read the latter directly; do not hand-roll `$HOME/.config`.

Flags and environment variables are **transient local overrides**: they apply for the run, are never pushed to the server, and are never written into the file. Everything else participates in propagation, described next.

#### The file is a peer editor, not an override layer

Preference sync is preserved in full. The config file, the Settings UI, and the server are **three writers to one logical value**, and an edit through any of them propagates to the other two:

```
config.toml ──(inotify)──┐
                         ├──> local preference store ──(debounced push)──> server
Settings UI ─────────────┘             ▲                                     │
                                       └───(pull on login / focus)───────────┘
                                                    └──> rewrite config.toml
```

The file is not a pin and does not suppress sync. It is a second input device onto the same store the UI writes to, and a materialized view of that store's synced section. Editing `dispose_action` in `$EDITOR` behaves exactly as if you had changed it in Settings: it lands in the store and pushes on the same debounce. A server pull that changes a value rewrites the file.

This is what "preserve sync across devices" requires, and it replaces the sticky-override model an earlier draft of this plan proposed. Two properties make it safe:

- **Writes are atomic** — temp file plus `rename(2)`, so a reader never sees a partial file and an open editor's `:w` can't interleave with a client write.
- **Comments and key order survive** — `toml_edit`, not `toml`. A client rewrite touches only the values it changed.

#### Two sections, different semantics

Not everything can sync — repointing your laptop at stage must not repoint your phone. The file makes the boundary visible rather than implicit:

```toml
# Synced across all your devices. Changing these here, in Settings,
# or on another device produces the same result.
[preferences]
dispose_action = "trash"
mark_as_read   = "on_open"
signature      = "-- \nsent from a machine I control"

# This machine only. Never leaves this device.
[local]
control_domain = "stage.cabalmail.example"
log_level      = "debug"
cache_max_mb   = 500
```

A key in the wrong section is a hard parse error naming both sections, not a silent no-op.

#### What the backend actually permits

`lambda/api/set_preferences/function.py` constrains this design in three ways that must be respected rather than discovered later:

1. **The synced key set is closed.** `APP_ALLOWED` enumerates exactly `mark_as_read`, `load_remote_content`, `dispose_action`, `theme`, `default_body_render_mode`, `folder_count_display`, `crash_reporting_enabled`, plus `default_from_address` and `signature`, with `name` at the top level. Unknown keys are rejected with a 400 *by design* ("so a client typo surfaces as a 400"). The client validates the `[preferences]` section against this set locally and reports the offending key with its file position — never by forwarding a 400.
2. **Per-key merge already exists**, at both levels (`app.#k = :v`). Concurrent multi-device edits are last-write-wins per key, and a client that omits a key cannot clobber it. This is why the Linux client simply never sends `crash_reporting_enabled` and the iOS setting survives untouched.
3. **There is no delete and no timestamp.** The row carries no `updated_at` or version attribute, and the Lambda only SETs. Two consequences:
   - **Deleting a line does not reset a preference.** A missing key means "no local opinion"; the store keeps its value and the client re-adds the line on the next rewrite. Resetting is `cabalmail config reset <key>`, which writes the default explicitly and pushes it.
   - **Offline file edits can lose a race.** Edit `config.toml` on a disconnected laptop while another device changes the same key, and the next foreground pull wins — the client cannot tell which edit is newer, because nothing records when either happened. Bounded and rare, but real; it is stated in `cabalmail.5` rather than papered over. Fixing it properly means adding per-key `updated_at` to the preferences row, which is a server change and out of scope here (open question 7).

Note also that `theme` exists twice — flat (`light`/`dark`, owned by the React app) and inside `app` (`system`/`light`/`dark`, owned by the Apple clients). Linux uses the `app` one, matching Apple. `default_from_address` and `signature` inherit the Lambda's validators (100 and 2000 characters, no control characters bar `\n`/`\t` in the signature); enforce those client-side so the user gets a position-anchored error instead of a rejected push.

#### What belongs where

| Layer | Contents | Rationale |
|---|---|---|
| `config.toml` `[preferences]` | The nine synced keys above, plus display name | Bidirectional: file ↔ UI ↔ server |
| `config.toml` `[local]` | Control domain and account; cache size caps and directory overrides; poll intervals; log level; proxy; keyring backend and `session_only`; WebKit toggles | Per-machine. Syncing these would be actively wrong |
| `$XDG_STATE_HOME` | Window geometry, pane positions, expanded-folder set, last-selected folder, logs | State, not configuration — nobody hand-edits a window size |
| `$XDG_DATA_HOME` | Drafts, outbox | User data; must survive a cache wipe |
| `$XDG_CACHE_HOME` | Envelope cache, message bodies, the fetched deployment descriptor | Safe to delete at any time |
| `$XDG_RUNTIME_DIR` | Single-instance lock / activation socket | Per-session, tmpfs |
| Secret Service | Cognito tokens | Never a file |

#### Consequences

- **No GSettings, no gschema.** With a TOML layer in place, a second configuration store earns nothing, and window geometry is state rather than configuration. Dropping it also removes `glib-compile-schemas` post-install hooks from all three packaging targets — a real simplification in Phases 2 and 8. The cost is departing from GNOME convention; the plan accepts that, because a GTK app with two config systems is worse than one with an unconventional single system.
- **`cabalmail --print-config`** dumps the effective values with per-key provenance — flag, env, user file, system file, server, or default — and, for synced keys, when they last pushed. A configuration with three writers that can't explain itself is a support burden; this pays for itself the first time someone files "my setting won't stick".
- **`cabalmail.5` man page** documenting every key, which section it belongs in, and whether it syncs. Installed by all three packages and generated from the same table that drives the parser, so it cannot drift.
- **The client materializes `config.toml` on first successful sign-in**, populated from the initial server pull, with the section comments shown above. This follows from the file being a view of the store rather than an override layer — a user should not have to create a file to discover what is editable. `config.example.toml` still ships to `/usr/share/doc/cabalmail/` as commented reference documentation.
- **File watching is core, not polish.** `inotify` via the `notify` crate is the mechanism that makes editor changes propagate at all. Debounce coalesces the write burst editors produce (write-temp, rename, truncate), and a parse failure holds the last-good store, surfaces the error in-app, and pushes nothing — a half-saved file must never reach the server.
- **Live reload** applies immediately for keys that permit it; keys needing a restart are marked in the man page and in `--print-config`.

### Distro support matrix

| Distro | GTK4 | libadwaita | webkitgtk-6.0 | Status |
|---|---|---|---|---|
| Arch / CachyOS | 4.22 | 1.9 | 2.52 (`extra`) | **Phase 2 target.** Development platform |
| Ubuntu 24.04 LTS | 4.14 | 1.4 | `libwebkitgtk-6.0-4` | **Phase 8 target.** Defines the API floor |
| Debian 13 (trixie) | ≥ 4.14 | ≥ 1.4 | packaged | Phase 8, same source package as Ubuntu |
| Fedora (current) | current | current | packaged | Phase 8, the `.rpm` reference build |
| RHEL 10 / CentOS Stream 10 | 4.x | present | expected | Phase 8, gated on the CI build proving it |
| **RHEL 9** | 4.6 | — | **absent** | **Not supported.** See below |

RHEL 9 ships the GTK3-era `webkit2gtk3` / `webkit2gtk4.0` packages, not the GTK4 `webkitgtk-6.0` introduced in WebKitGTK 2.40 ([Repology](https://repology.org/project/webkitgtk/packages), [WebKitGTK API versions](https://blogs.gnome.org/mcatanzaro/2025/04/28/webkitgtk-api-versions/)). A GTK4 + WebKit6 application therefore cannot be packaged for RHEL 9 from distro dependencies. "RHEL support" in this plan means **RHEL 10 and Fedora**. If RHEL 9 becomes a hard requirement, the only realistic answer is a Flatpak carrying its own runtime — a scope change, not a packaging tweak, and one this plan deliberately does not absorb.

### Repository layout

A new top-level directory, sibling to `apple/`, `android/`, and `react/admin`:

```
linux/
  Cargo.toml                       # workspace root
  Cargo.lock                       # committed — packaging needs reproducible deps
  rust-toolchain.toml              # pinned toolchain
  clippy.toml  rustfmt.toml
  README.md

  cabalmail-kit/                   # spiritual sibling of CabalmailKit — NO gtk/webkit deps
    Cargo.toml
    src/
      lib.rs
      config/                      # layered user config (TOML) + deployment descriptor fetch
      auth/                        # Cognito USER_PASSWORD_AUTH, MFA, token refresh
      secret/                      # Secret Service (oo7) + trait for test doubles
      api/                         # ApiClient trait + reqwest impl, one module per group
      models/                      # Envelope, Message, Address, Folder, FolderTree, Flags…
      mime/                        # header decode, MIME parse, attachment plan
      cache/                       # envelope + body caches, UIDVALIDITY keyed, LRU bodies
      compose/                     # Draft, ReplyBuilder, SignatureFormatter, MailtoUrl
      outbox/                      # on-disk send queue
      policy/                      # pure UI-decision types (see Phase 2 note)
      prefs/                       # Preferences + server sync
    tests/
      fixtures/                    # golden JSON per endpoint
      *.rs

  cabalmail-gtk/                   # the application
    Cargo.toml
    build.rs                       # gresource + blueprint compilation
    src/
      main.rs  application.rs  runtime.rs   # spawn_to_ui! lives here
      ui/{auth,mail,compose,addresses,folders,settings}/
    resources/
      *.blp                        # Blueprint UI definitions
      icons/                       # symbolic icons
      editor/                      # editor.html + editor-bridge.js (first-party)
                                   #   marked.umd.js + turndown.js are gitignored,
                                   #   materialized by scripts/sync-vendored.sh
      reader/                      # reader.css, reader-shim.js
    data/
      com.cabalmail.Cabalmail.desktop.in
      com.cabalmail.Cabalmail.metainfo.xml.in
      config.example.toml          # commented reference, installed to /usr/share/doc
      cabalmail.5.md               # man page source; keys generated from the parser table

  xtask/                           # cargo xtask: sync-vendored, package, smoke, fixtures
  scripts/
    sync-vendored.sh               # mirrors apple/scripts/sync-vendored.sh
  packaging/
    arch/PKGBUILD  arch/.SRCINFO
    debian/                        # Phase 8
    rpm/cabalmail.spec             # Phase 8
```

`cabalmail-kit` is a library crate with no binary and no GUI dependency. Everything that can be decided without a widget lives there — including the pure policy types described in Phase 2. This is what makes the client testable.

### Working agreement for AI-executed phases

Each numbered work item below is sized to one branch and one PR. Executors must observe:

1. **One work item per PR.** Do not batch items across phase boundaries.
2. **Every PR is green on `cargo xtask ci` locally before push.** That target runs fmt, clippy, kit tests, and app tests in the same order CI does.
3. **Every PR adds tests in the same commit as the code.** The kit's coverage floor is enforced from Phase 2; a PR that lowers it fails.
4. **Contract changes are fixture changes.** Any change to how the client reads a Lambda response updates the golden fixture under `cabalmail-kit/tests/fixtures/` in the same PR.
5. **Changelog fragment required** — `changelog.d/<slug>.<category>.md`, per [`changelog.d/README.md`](../../changelog.d/README.md). See the Open Questions on whether a `Linux:` prefix is adopted.
6. **Ship through stage.** Down-merge `origin/stage`, resolve conflicts, push, open the PR against `stage`.
7. **Never widen scope silently.** If a work item turns out to need something the plan didn't anticipate, say so in the PR description rather than absorbing it.

---

## Phase 1: Workspace Scaffolding

Goal: a workspace that builds an empty window, with the async bridge and the crate split already correct.

### 1. Cargo workspace

- `linux/Cargo.toml` declaring members `cabalmail-kit`, `cabalmail-gtk`, `xtask`.
- `rust-toolchain.toml` pinning a stable channel; MSRV documented in `linux/README.md` and set to Debian stable's rustc so Phase 8 has no surprise.
- `Cargo.lock` committed — distro packaging builds offline against vendored crates, which requires a lock.
- `rustfmt.toml` and `clippy.toml`; `#![deny(warnings)]` is *not* used (it breaks downstream builds on new compiler versions) — CI passes `-D warnings` instead.

### 2. `cabalmail-kit` skeleton

- Crate with module stubs matching the layout above. No GTK, no WebKit in `Cargo.toml` — add a CI check (Phase 2, work item 6) that fails if one ever appears.
- `CabalmailError` enum covering the error taxonomy the Apple client settled on: `network`, `auth`, `http(status, body)`, `decode`, `protocol`, `cancelled`. The distinction between transport failure and application rejection is load-bearing for the outbox (Phase 5) — model it now.

### 3. Layered configuration

Land the configuration store and schema here, before anything reads a setting — retrofitting precedence and provenance after six phases of direct reads is the predictable disaster.

- `config/` in the kit: a `Settings` struct where every field records both its value and its **provenance** (flag / env / user file / system file / server / default). Provenance is not a debugging afterthought — `--print-config`, Phase 6's Settings UI, and the propagation rules all read it.
- Split the schema into the `[preferences]` (synced) and `[local]` (machine-only) sections, with the synced set validated against the Lambda's closed `APP_ALLOWED` list. A key in the wrong section is an error naming both.
- Parse with `toml_edit`; write atomically (temp + `rename(2)`) preserving comments and key order.
- Resolve `$XDG_CONFIG_HOME` via `directories`; walk `$XDG_CONFIG_DIRS` in order for system defaults.
- `cabalmail --print-config` emitting the effective table with a provenance column, and `cabalmail config set` / `config reset <key>`.
- Generate `config.example.toml` and the `cabalmail.5` key list from the same parser table, with a test asserting no key exists in the parser that is missing from the man page.
- Malformed config is a **hard, precise failure** — file, line, column, and the offending key — never a silent fall-back to defaults. A user who typo'd a key needs to be told, not quietly ignored.

The propagation machinery itself (inotify watching, debounce, push/pull wiring) lands in **Phase 6** alongside the Settings UI and the server sync it coordinates with. Phase 1 builds the store, the schema, and the file I/O it depends on — deliberately, so the store is well-tested before three writers are pointed at it.

### 4. `cabalmail-gtk` shell

- `AdwApplication` with app ID `com.cabalmail.Cabalmail`, a single `AdwApplicationWindow`, and a placeholder `AdwStatusPage`.
- GResource bundle wired through `build.rs`; Blueprint compilation with a graceful fallback if `blueprint-compiler` is absent.
- `runtime.rs`: the tokio runtime handle plus the `spawn_to_ui!` macro described above, with unit tests proving a spawned future's result reaches a `glib::MainContext` callback.
- `.desktop` and AppStream `metainfo.xml`. **No gschema** — window geometry is state (`$XDG_STATE_HOME`), configuration is TOML, and synced preferences are server-side. See the Configuration model.

### 5. `xtask`

Subcommands, each a thin wrapper so both humans and CI have one spelling:

```
cargo xtask sync-vendored     # marked + turndown from react/admin/node_modules
cargo xtask ci                # fmt --check, clippy -D warnings, kit tests, app tests
cargo xtask package arch      # build PKGBUILD in a container, run namcap
cargo xtask smoke             # install the built package, launch headless, assert
cargo xtask fixtures          # regenerate golden fixtures from a live stage deployment
```

### Phase 1 verification

- `cargo build --workspace` succeeds on Arch.
- `cargo test -p cabalmail-kit` runs with no display server and no network.
- `cargo run -p cabalmail-gtk` opens a window titled "Cabalmail".
- `cargo tree -p cabalmail-kit | grep -E 'gtk|webkit'` returns nothing.
- `cabalmail --print-config` on a clean system reports every key as `default`. Adding `~/.config/cabalmail/config.toml` with one key reports that key as `user-file` and the rest unchanged; setting the matching `CABALMAIL_*` variable flips it to `env`. Running with `XDG_CONFIG_HOME` pointed at a temp directory relocates the lookup — no hard-coded `~/.config` anywhere.
- A config file with a typo'd key fails with file, line, column, and the bad key; it does not start with defaults. A synced key placed under `[local]` (or vice versa) fails naming both sections.
- A client write (`cabalmail config set`) preserves surrounding comments and key order, and is atomic — a concurrent reader sees either the old or the new file, never a truncated one.
- Every key in `[preferences]` is accepted by the Lambda's `APP_ALLOWED` set; a test asserts the client's synced-key list and the Lambda's list are identical, so a future divergence fails CI rather than producing 400s at runtime.

---

## Phase 2: Build Pipeline, Packaging & Test Harness

Goal: everything after this phase is developed under green CI and produces an installable Arch package on every push. Nothing user-facing ships in this phase.

### 1. Workflow layout

New `.github/workflows/linux.yml`, modelled on `apple.yml`: triggered by `workflow_dispatch` and by pushes to `main` / `stage` under `linux/**` and `.github/workflows/linux.yml`. Like `apple.yml`, it deploys nothing to AWS.

```yaml
jobs:
  lint:            # ubuntu-latest — rustfmt --check, clippy -D warnings
  kit-test:        # ubuntu-latest — cargo test -p cabalmail-kit (no GTK, no display)
  app-build:       # container: ubuntu:24.04 — API floor build, gtk/adw/webkit dev pkgs
  app-test:        # container: ubuntu:24.04 — xvfb-run cargo test -p cabalmail-gtk
  package-arch:    # container: archlinux:base-devel — makepkg + namcap
  smoke:           # needs: package-arch — install, launch under xvfb, assert startup
  coverage:        # cargo-llvm-cov on the kit; fails under the floor
```

`app-build` runs against **Ubuntu 24.04**, not Arch. Building the API floor on every push is the entire point — an Arch-only CI would let GTK 4.16+ API land silently and surface it as a Phase 8 packaging failure months later.

### 2. Toolchain pinning

- Rust from `rust-toolchain.toml`, installed by `dtolnay/rust-toolchain` pinned to a commit SHA (the repo's convention — every third-party action in `apple.yml` is SHA-pinned; match it).
- System dependencies installed by an explicit package list per container, kept in `linux/packaging/deps/<distro>.txt` so the PKGBUILD, the Debian control file, and the CI containers all read one source.
- `cargo-llvm-cov`, `cargo-deny`, `namcap` installed by pinned version.

### 3. Test harness

This is the substance of the phase. Four layers:

**(a) Kit unit tests — `cargo test -p cabalmail-kit`.** Pure logic: MIME parsing, header decoding, reply construction, signature formatting, folder-tree assembly, cache eviction, preference reconciliation. No network, no display, no filesystem beyond `tempfile`. This is where the coverage floor is enforced and where the bulk of the suite lives, mirroring the 49-file `CabalmailKitTests` suite.

**(b) HTTP contract tests — `wiremock` + golden fixtures.** Every endpoint the client calls gets a fixture under `cabalmail-kit/tests/fixtures/<endpoint>/<case>.json` and a test that serves it through `wiremock` and asserts the decoded Rust type. Fixtures are captured from a real stage deployment by `cargo xtask fixtures` and committed. Two properties this buys:

- A Lambda response-shape change breaks the Linux client in CI rather than at runtime.
- The fixture corpus is a written specification of the API contract — useful to the Android effort in the same version slot, and to anyone touching `lambda/api/`.

Redact tokens and real addresses on capture; `cargo xtask fixtures` enforces this and fails on anything matching a JWT or a live mail domain.

**(c) Pure policy types.** `apple/CabalmailTests/` is 24 files of tests over *pure* types that encode UI decisions without owning widgets. That file list is the specification for this layer. Port the equivalents into `cabalmail-kit/src/policy/` as plain functions and test them in layer (a):

| Apple type | Linux equivalent | Decision it encodes |
|---|---|---|
| `CompactColumnPolicy` | `policy::layout` | When the split view collapses |
| `ReaderToolbarLayout` / `ReaderHeaderHeightPolicy` | `policy::reader` | Which toolbar actions appear, header sizing |
| `MessageRowIdentity` | `policy::row_identity` | Stable list identity across refresh |
| `ComposeCancelPolicy` / `ComposeCancelChoice` | `policy::compose_cancel` | Save / discard / keep-editing on close |
| `DisposeIntent` / `RowDisposal` | `policy::dispose` | Archive vs Trash vs Restore per folder |
| `HTMLRewrite` | `policy::html_rewrite` | Remote-content and link rewriting before render |
| `MessageListPillCount` | `policy::pills` | All / Unread / Flagged counts |
| `SearchSourceFolderIndex` | `policy::search_source` | Which folder a cross-folder hit came from |

Anything in this table that ends up needing a `gtk::Widget` has been modelled wrong.

**(d) Widget and smoke tests.** Thin by design. `cargo test -p cabalmail-gtk` under `xvfb-run` covers construction of each top-level view against a fake `ApiClient`, and the `spawn_to_ui!` bridge. The `smoke` job goes further: installs the built package into a clean container, launches it with `--self-test` against a `wiremock` instance, and asserts the process reaches a signed-out main window and exits 0. That flag is a real code path added in this phase — it is the only end-to-end assertion that the *packaged artifact* works, as opposed to the source tree.

### 4. Arch packaging

`packaging/arch/PKGBUILD`:

- `pkgver` derived from the latest semver git tag (matching `scripts/promote.sh`, which is the version source of truth); `pkgrel` reset on version bump.
- `depends=(gtk4 libadwaita webkitgtk-6.0 glib2)`, `makedepends=(rust cargo git)`.
- Installs `config.example.toml` to `/usr/share/doc/cabalmail/` and `cabalmail.5` to the man path. It does **not** install anything into `/etc/xdg/cabalmail/` — that path is reserved for the administrator, and shipping a file there would make "no system config present" indistinguishable from "administrator chose these defaults".
- `build()` runs `cargo build --release --frozen --offline` against vendored crates.
- `check()` runs `cargo test -p cabalmail-kit` — kit tests need no display, so they run inside `makepkg` unmodified.
- `namcap` clean on both the `PKGBUILD` and the built package; CI fails on any namcap error.

**The vendored-JS problem.** `editor.html` needs `marked.umd.js` and `turndown.js`. The Apple client materializes them from `react/admin/node_modules/` at build time, which is right for a developer checkout but wrong for `makepkg` — `prepare()` must not reach the network, and requiring `nodejs`/`npm` as a makedepend to run `npm ci` breaks that rule. The resolution:

- Add the upstream npm tarballs as explicit `source=()` entries pinned to the exact versions in `react/admin/package.json` (`marked@^18.0.2`, `turndown@^7.2.4`), with `sha256sums`. `makepkg` fetches and checksums them like any other source; the build is offline-after-fetch and reproducible.
- Add a CI drift check that resolves `react/admin/package.json` and fails if the `PKGBUILD` pins diverge. This preserves the "React's manifest is the single source of truth" property the Apple client relies on, including Dependabot coverage, without committing upstream bytes.
- Developer checkouts keep using `scripts/sync-vendored.sh` (via `cargo xtask sync-vendored`), identical to the Apple flow.

### 5. Release artifacts

The `package-arch` job uploads the `.pkg.tar.zst` and its `.SRCINFO` as workflow artifacts on every run. Publishing to the AUR is a manual, human-gated step — not automated in this phase, and not something an AI-executed work item should perform.

### 6. Guard rails

- `cargo deny check` for licence and advisory policy.
- A CI step asserting `cabalmail-kit` has no GTK/WebKit dependency (`cargo tree` grep).
- A CI step asserting the reader WebView's settings are hardened, grepping for `enable_javascript(false)` on the reader configuration — the analog of the CLAUDE.md rule forbidding `allow-scripts` on the React reader iframe. Add the corresponding prohibition to `CLAUDE.md` in this phase.

### Phase 2 verification

- A push to `stage` under `linux/**` runs all eight jobs green.
- `cargo xtask package arch` produces an installable package on a clean Arch container.
- `cargo xtask smoke` passes against that package.
- Deliberately introducing a GTK 4.16-only call fails `app-build` and not `lint` — proving the floor is enforced where intended.
- Deliberately corrupting a fixture fails `kit-test`.

---

## Phase 3: Configuration, Authentication & API Client

### 1. Runtime configuration

Two distinct things are called "config" in this codebase, and conflating them will cause bugs. Keep the names apart in code and docs:

| | **Deployment descriptor** | **User config** |
|---|---|---|
| Source | `https://{control_domain}/config.json`, written by Terraform | The user's text editor |
| Owner | The deployment | The user |
| Path | `$XDG_CACHE_HOME/cabalmail/deployment.json` (cached) | `$XDG_CONFIG_HOME/cabalmail/config.toml` |
| Editable | No — refetched and overwritten | Yes, that's the point |
| Type | `Deployment` | `Settings` |

`config/`: fetch the descriptor, decode into a `Deployment` struct mirroring `CabalmailKit.Configuration` — `control_domain`, `domains[]`, `invokeUrl`, `cognitoConfig`. Derive `imap_host` with the same rule the React app and Apple client use: a `dev.` prefix is replaced by `imap.`, otherwise `imap.` is prepended.

The cached copy is deliberately in `$XDG_CACHE_HOME` — deleting it must be harmless, and a stale descriptor after a deployment change is exactly the bug a cache-clear should fix.

The control domain comes from `Settings.control_domain` (so it can be set in `config.toml`, which is how someone pins a workstation to stage) or is entered on first launch. One binary works against dev / stage / prod either way.

### 2. Authentication

`auth/`: hand-rolled `USER_PASSWORD_AUTH` against `https://cognito-idp.<region>.amazonaws.com/`, mirroring `CognitoAuthService`. Required surface:

- `sign_in` returning `SignedIn` or `MfaRequired(Totp | Sms)`
- `submit_mfa_code`, `sign_up`, `confirm_sign_up`, `resend_confirmation_code`
- `forgot_password`, `confirm_forgot_password`, `sign_out`
- TOTP enrollment: `totp_enabled`, `begin_totp_enrollment` (returns the shared secret for an `otpauth://` QR), `confirm_totp_enrollment`
- Token refresh with a margin before expiry, serialized so concurrent 401s trigger one refresh

### 3. Secret storage

`secret/`: a `SecretStore` trait with an `oo7` Secret Service implementation and an in-memory double for tests. Tokens stored as one JSON blob under a label keyed to `(control_domain, username)`, so two accounts never collide — the account-scoping property `Preferences.activate` provides on Apple.

**Failure mode to handle explicitly:** many minimal WM setups run no Secret Service provider. Detect this at sign-in, and present an actionable message ("No keyring service found — install gnome-keyring or KWallet, or run with `--session-only` to keep credentials in memory for this session") rather than a generic error. Silently falling back to a plaintext file is not acceptable.

### 4. API client

`api/`: an `ApiClient` trait plus a `reqwest` implementation, grouped as the Apple client groups them. All calls carry the Cognito ID token as `Authorization`. Folder paths use `/` on the wire and are normalized server-side.

| Group | Endpoints |
|---|---|
| Addresses | `/list`, `/new`, `/revoke`, `/suspend_address`, `/reinstate_address`, `/set_favorite`, `/list_my_domains` |
| Folders | `/list_folders`, `/new_folder`, `/delete_folder`, `/subscribe_folder`, `/unsubscribe_folder`, `/folder_status` |
| Messages | `/list_messages`, `/list_envelopes`, `/search_envelopes`, `/fetch_message`, `/list_attachments`, `/fetch_attachment`, `/fetch_inline_image` |
| Operations | `/set_flag`, `/move_messages`, `/purge_messages`, `/empty_trash` |
| Compose | `/send`, `/save_draft`, `/upload_url` |
| State | `/get_preferences`, `/set_preferences`, `/get_nav_state`, `/set_nav_state` |
| Other | `/fetch_bimi` |

`/push_register`, `/push_deregister`, and `/push_envelope` are **not** implemented — they are APNs-specific (see Phase 7).

### 5. Models and caching

`models/`: `Envelope` (including the threading identity — `message_id`, `in_reply_to`, `references`), `Message`, `Address`, `Folder`, `FolderTree`, `Flags`, `AuthResults`, `SearchQuery` / `SearchResult`.

`cache/`: per-folder envelope cache keyed by UIDVALIDITY under `$XDG_CACHE_HOME/cabalmail/envelopes/`; raw `.eml` bodies under `bodies/`, LRU-evicted by mtime past a configurable cap (default 200 MB, matching Apple).

`mime/`: RFC 2047 header decoding, multipart walking, attachment descriptor extraction, inline-image `cid:` resolution. Fetch full bodies and parse client-side — there is no `fetchPart` over the API.

### Phase 3 verification

- Contract tests cover every endpoint in the table against committed fixtures.
- Sign-in against the stage deployment succeeds from a scratch container, including a TOTP-challenged account.
- Killing the keyring daemon produces the actionable message, not a panic.
- Tokens survive an app restart; an expired access token triggers exactly one refresh under ten concurrent requests.

---

## Phase 4: Mail Reading

### 1. Shell and folder sidebar

`AdwNavigationSplitView` three-pane: folder list, message list, reader. Collapses per `policy::layout` at narrow widths. Folder tree from `/list_folders` with unread badges from `/folder_status`; expand/collapse state persisted locally.

### 2. Message list

`GtkListView` backed by a `gio::ListStore` — virtualized, which the plan assumes rather than retrofits. Positional pagination via `/list_messages?offset=&limit=`, then `/list_envelopes` for the visible window.

- Sort by received date, sent date, sender, subject (`SortCriterion` equivalent).
- All / Unread / Flagged filter pills with counts from `policy::pills`.
- Multi-select with `GtkMultiSelection` for bulk move / flag / read / dispose.
- Swipe-equivalent row actions via `AdwSwipeTracker` on touch, context menu everywhere.
- Pull-to-refresh is not a desktop idiom — refresh is Ctrl+R and a header button.

### 3. Reader

Body render in a `WebKitWebView`, hardened:

- `enable_javascript(false)` on the reader view. Non-negotiable; CI greps for it.
- Remote content blocked by default via `WebKitWebContext` request interception, honouring the `load_remote_content` preference (off / ask / always). "Ask" shows an `AdwBanner` with a per-message allow.
- Inline images served through a custom `cabalmail-cid:` URI scheme handler backed by `/fetch_inline_image`.
- All navigation intercepted in `decide-policy`; links never load in-view. Hovering shows the target; activating opens the system browser after confirmation for mismatched display text (the `LinkMenu` / `HTMLRewrite` behaviour).
- Plain-text bodies render in a `GtkTextView` with linkification, not through WebKit.
- `AuthResults` line (SPF / DKIM / DMARC) and BIMI avatar via `/fetch_bimi`, cached.

Attachments strip with presigned-URL download through `/fetch_attachment`, saved via `GtkFileDialog`.

### 4. Search

First-class scope, not a filter: `/search_envelopes` across one folder or all subscribed folders, with a filter dialog (from / to / subject / body / date range / flags) and paginated results carrying their source folder.

### 5. Resume cursor

`/get_nav_state` on launch; if the stored folder/message differs from the default, offer restore via an `AdwToast` with an action. Push `/set_nav_state` debounced on navigation.

### Phase 4 verification

- Reader renders a corpus of adversarial fixtures — remote images, `cid:` images, malformed MIME, 8-bit headers, HTML with scripts — without executing script and without leaking a remote request while blocking is on.
- A 50,000-message folder scrolls smoothly and issues bounded requests.
- Cross-folder search returns hits attributed to the right folders.

---

## Phase 5: Mail Composition & On-the-Fly `From`

### 1. Compose window

A separate `AdwWindow` per draft (multi-window compose is a desktop expectation, and matches the Apple compose scene). Dual-mode body via `AdwViewSwitcher`: **Rich Text** and **Markdown**, exactly as the Apple and React composers do.

The rich pane is a `contenteditable` inside a `WebKitWebView` — JS **enabled** here, loading the first-party `editor.html` + `editor-bridge.js` with marked and turndown. This is the same asset set the Apple client uses, from the same version pins, which is why the composer behaviour matches without reimplementation. The GTK toolbar drives it over a `WebKitUserContentManager` script-message bridge.

At send time, port `computeMessageBodies()`'s four-way table verbatim (both-empty, rich-only, markdown-only, both-filled) so every message ships populated `text/plain` and `text/html` parts. This is pure logic and belongs in `cabalmail-kit/src/compose/` with tests.

### 2. From-address picker

First item is always **Create new address…**, opening the mint dialog inline (username / subdomain / domain / optional comment, with a **Random** button). Domains come from `/list_my_domains`. This is the product's signature interaction — it must be one click from compose.

### 3. Reply / Reply All / Forward

Port `ReplyBuilder` as a pure function: idempotent `Re:` / `Fwd:` prefixing, `In-Reply-To` / `References` threading from the envelope's threading identity, reply-all deduplication and self-exclusion, and the "default From to the original's addressee" rule that makes an on-the-fly address reusable across a thread.

Signature insertion via the RFC 3676 `"-- "` delimiter, ported from `SignatureFormatter`.

### 4. Drafts

Local buffer plus server sync, matching `docs/draft-sync-and-threading.md`:

- Local autosave every 5 s to `$XDG_DATA_HOME/cabalmail/drafts/`, one JSON per draft — the crash-recovery story.
- Server save via `/save_draft` on close-without-send (always) and on a 60 s debounce while composing; skipped while the body is empty, a send is in flight, or another save is running.
- Last-writer-wins on `(uidvalidity, uid)`, passing prior coordinates as `replaces_*`.
- Opening a message in `Drafts` offers **Edit Draft**, reseeding compose from the fetched copy.
- Sending from a synced draft passes `discard_draft_*` so the server expunges the Drafts copy on success.

### 5. Send and outbox

`/send` owns the Outbox APPEND, SMTP submission, and the Sent copy — the client performs no APPEND. Classify failures before queueing, exactly as `CabalmailClient.send` does: transport and network errors queue into the on-disk outbox and raise a warning toast; application-level rejections (auth, malformed recipient, permanent 5xx) surface immediately so the compose window can correct them. Drain on connectivity restore, `maxAttempts = 10`.

Attachments upload through `/upload_url`.

### 6. Desktop compose entry points

- `mailto:` handler registered in the `.desktop` file, parsed by the ported `MailtoUrl`.
- "Send to" integration is out of scope for 1.1.0.

### Phase 5 verification

- The four-way body table produces byte-identical `text/plain` and `text/html` to the React composer for a shared corpus of Markdown inputs. Assert this in tests — it is the highest-value regression guard in the phase.
- A draft composed on Linux opens correctly in the iOS client and vice versa.
- Killing the app mid-compose recovers the draft on relaunch.
- Airplane-mode send queues, then drains on reconnect.

---

## Phase 6: Address & Folder Management + Settings

### 1. Addresses

`AdwPreferencesPage`-style list from `/list`: create, revoke, suspend, reinstate, favorite. Search and favorites-first sorting. Revocation is a destructive `AdwAlertDialog` naming the address.

### 2. Folders

Tree from `/list_folders`: create (with parent), delete, subscribe / unsubscribe. Deleting a non-empty folder warns with its message count.

### 3. Settings

`AdwPreferencesWindow`, groups mirroring the Apple settings surface, persisted through the kit's `Preferences` with the **same wire keys** so the setting follows the user across platforms:

| Group | Setting | Wire key |
|---|---|---|
| Account | Username, control domain (read-only), Sign Out | — |
| Reading | Mark as read (manual / on open) | `mark_as_read` |
| Reading | Load remote content (off / ask / always) | `load_remote_content` |
| Reading | Default body render mode | `default_body_render_mode` |
| Composing | Default From address | `default_from_address` |
| Composing | Signature | `signature` |
| Composing | Display name | `name` (top-level, shared with web) |
| Actions | Dispose action (Archive / Trash) | `dispose_action` |
| Appearance | Theme (System / Light / Dark) | `theme` |
| Appearance | Folder count display | `folder_count_display` |
| Diagnostics | Debug log viewer + export | — |

Sync semantics match Apple: server-wins pull on login and on window focus, debounced push on local edit, stored under the row's `app` map so the web client's flat keys are untouched. A revoked `default_from_address` falls back to None.

#### Three-way propagation

This is where the config file, the Settings UI, and the server are wired into one another (the model is specified under Configuration model; Phase 1 built the store it needs). Work items:

- **File → store.** Watch `config.toml` with `notify`, debounced to coalesce the multi-event burst editors emit on save. Reparse, diff against the store, apply changed keys. A parse failure keeps the last-good store, surfaces an in-app error banner with the file position, and pushes nothing.
- **Store → server.** Changed `[preferences]` keys push on the existing debounce, whether the change originated in the file or the UI. `[local]` keys never push.
- **Server → store → file.** A pull that changes a value updates the store and rewrites the file atomically, touching only the changed values and leaving comments intact.
- **Loop suppression.** The rewrite in step three will fire the watcher from step one. Suppress by comparing against the last-written content rather than by timing windows — a debounce race here produces an infinite push loop, and it is the single most likely bug in this phase. Test it explicitly with a fake clock.
- **Settings UI** reflects external changes live: a key edited in `$EDITOR` moves its control without a reopen.

Controls are never rendered read-only on account of the file — the two are peers, and either can be used at any time. The window links to `config.toml` and to `man 5 cabalmail`, so the GUI is a discovery path for the text interface rather than a replacement for it.

`crash_reporting_enabled` has no Linux consumer (MetricKit is Apple-only) — the key is read and preserved on write so a round trip through the Linux client never clobbers the iOS setting, but no toggle is shown.

### Phase 6 verification

- Changing a preference on Linux is reflected in the iOS client after a foreground, and vice versa.
- A Linux preferences write leaves the web client's `theme` / `accent` / `density` and the Apple `crash_reporting_enabled` intact.
- Address lifecycle operations round-trip against stage.
- **Round-trip in all six directions.** Editing `dispose_action` in `$EDITOR` moves the Settings control and reaches the server; changing it in Settings rewrites the file; changing it on the iOS client updates both on next foreground.
- Rewrites preserve user comments and key ordering, and are atomic under a concurrent reader.
- **No push loop.** A server-driven rewrite does not trigger a push. Assert this with a fake clock and a request counter, not by watching it not happen for a while.
- A `[local]` key never appears in a `/set_preferences` request body.
- A syntactically broken save holds the last-good values, shows the error with its file position, and issues no request.
- `cabalmail config reset <key>` writes the default and propagates it; deleting the line instead leaves the value intact and the line reappears on the next rewrite, as documented.

---

## Phase 7: Desktop Integration & Polish

### 1. New-mail notification (no push)

APNs is unavailable, so:

- Poll `/folder_status` on an adaptive interval — frequent while the window is focused, backing off when unfocused or on battery (read `UPower` over D-Bus; degrade gracefully when absent).
- Raise notifications with `gio::Notification` via `GApplication::send_notification`, which routes to `org.freedesktop.Notifications` and through the portal under sandboxing. Actions: **Open**, **Mark as read**, **Archive**.
- Show an unread count on the launcher via the Unity LauncherEntry D-Bus interface where the desktop supports it.

**Web Push is the documented seam, not 1.1.0 scope.** Supporting it means teaching `push_register` a platform discriminator and giving `push_dispatch` an RFC 8030 / VAPID transport alongside APNs. The 1.2.x browser-extension plan will want the same thing; whoever gets there first should build it for both. Recorded in Open Questions.

### 2. Keyboard and menus

Port the Apple command set to GTK actions with `AdwPreferencesWindow`-consistent accelerators: Reply (Ctrl+R), Reply All (Ctrl+Shift+R), Forward (Ctrl+Shift+J), Mark Read/Unread (Ctrl+T), Flag (Ctrl+Shift+8), Move to Folder (Ctrl+M), New Message (Ctrl+N), Refresh (Ctrl+Shift+R... resolve the collision with Reply All in favour of F5 for refresh), Dispose (Delete). Full keyboard navigation of list and reader; a shortcuts window (Ctrl+?).

Note the Apple lesson: dispose is deliberately window-scoped rather than app-global so it cannot fire from a compose window mid-draft. GTK actions have the same hazard — scope dispose to the mail window.

### 3. Session and window state

Window geometry, pane positions, and the expanded-folder set as JSON under `$XDG_STATE_HOME/cabalmail/` — state, not configuration, and not worth a second config system (see Configuration model). Restore the last folder from the nav-state cursor. Optional start-minimized-to-notifications for users who keep mail running.

### 4. Offline

Cached envelopes and bodies readable offline; compose available with sends queued to the outbox. An `AdwBanner` reports connectivity loss, sourced from `NetworkManager` over D-Bus with a poll fallback.

### 5. Accessibility and theming

- Correct `AccessibleRole` and labels on every custom widget; screen-reader pass with Orca.
- Reader honours the system dark preference — inject a `prefers-color-scheme` shim into the WebView, and never restyle sender HTML beyond that.
- High-contrast and large-text respected via libadwaita's style manager.

### 6. Diagnostics

`DebugLogStore` equivalent in the kit: an in-memory ring buffer with level filtering, viewable in Settings and exportable. Also written to `$XDG_STATE_HOME/cabalmail/` and surfaced through `--log-level`.

### Phase 7 verification

- Notifications appear on GNOME and KDE with working actions.
- Orca can drive the full read / reply / send loop.
- Disconnecting the network mid-session produces the banner, offline reading, and a queued send that drains on reconnect.
- Dispose fires from the mail window and not from a focused compose window.

---

## Phase 8: Debian & RHEL Packaging

### 1. Debian / Ubuntu

- `packaging/debian/` with `control`, `rules` (dh with `dh-cargo`), `changelog` generated from the repo's release tags.
- Build in `debian:trixie` and `ubuntu:24.04` containers; `lintian` clean at the error level.
- Vendored crates in the source package — Debian builds are offline.
- The same npm-tarball pinning strategy as the PKGBUILD for marked / turndown.

### 2. RHEL / Fedora

- `packaging/rpm/cabalmail.spec` built in `fedora:latest` and `quay.io/centos/centos:stream10`.
- `rpmlint` clean at the error level.
- **RHEL 9 is out of scope** for the reasons in the support matrix. State it in `linux/README.md` so it is not rediscovered.

### 3. CI matrix extension

`package-deb` and `package-rpm` jobs join `linux.yml`, each with a matching `smoke` job that installs into a clean container of the same distro and runs `--self-test`. Artifacts uploaded per push; repository publication stays manual.

### Phase 8 verification

- Each package installs cleanly into a fresh container of its distro and launches under xvfb.
- Uninstall leaves no files outside `$XDG_*` user directories.
- The `.desktop` file registers a working `mailto:` handler on each distro.
- `man 5 cabalmail` renders on each distro, and every key it documents is accepted by the parser (the Phase 1 drift test, re-run against the installed page).
- A file dropped at `/etc/xdg/cabalmail/config.toml` is picked up as system defaults and is correctly overridden by a user file — verified on each distro, since `XDG_CONFIG_DIRS` defaults vary.

---

## Parity matrix

Apple client feature → Linux status. Anything marked *deferred* is deliberate, not an oversight.

| Feature | Linux | Phase |
|---|---|---|
| Sign-in, sign-up, forgot password | Yes | 3 |
| TOTP / SMS MFA | Yes (TOTP enrollment included) | 3 |
| Folder list, unread badges, subscribe/unsubscribe | Yes | 4, 6 |
| Message list: virtualized, sortable, filter pills | Yes | 4 |
| Bulk multi-select operations | Yes | 4 |
| Reader: HTML, plain text, remote-content policy, inline images | Yes | 4 |
| SPF/DKIM/DMARC line, BIMI avatar | Yes | 4 |
| Attachments: list, download | Yes | 4 |
| Cross-folder structured search | Yes | 4 |
| Resume cursor | Yes | 4 |
| Compose: rich text + Markdown, shared JS pipeline | Yes | 5 |
| On-the-fly `From`, mint-from-compose | Yes | 5 |
| Reply / Reply All / Forward with threading | Yes | 5 |
| Drafts: local buffer + cross-device sync | Yes | 5 |
| Outbox with transient/permanent classification | Yes | 5 |
| Address lifecycle: create, revoke, suspend, reinstate, favorite | Yes | 6 |
| Folder management | Yes | 6 |
| Server-synced preferences | Yes | 6 |
| Theme, accessibility, keyboard, offline | Yes | 7 |
| Debug log viewer and export | Yes | 7 |
| `mailto:` handler | Yes | 5 |
| **Push notifications (APNs)** | **Polling + desktop notifications** | 7 |
| **Contacts integration** | **Deferred** — no cross-desktop equivalent of the Apple Contacts store; recipient autocomplete draws on sent-message history instead | — |
| **Siri / App Intents** | **Not applicable** | — |
| **Watch companion, visionOS, MetricKit** | **Not applicable** | — |
| Admin surfaces (users, DMARC reports, domain access) | Out of scope — web app | — |
| **Hand-editable config file, man page, `--print-config`** | **Beyond parity** — no Apple equivalent; a platform expectation, not a port | 1, 6 |

---

## Out of scope for 1.1.0

- Distribution through official Arch, Debian, or Fedora repositories. AUR and CI artifacts only.
- Flatpak and Snap. A Flatpak becomes worth revisiting only if RHEL 9 support turns into a requirement.
- Web Push. Polling covers the need; the transport work is shared with the browser extension and belongs with whichever effort needs it first.
- Multiple simultaneous accounts. The storage layer is account-scoped from Phase 3 so this is additive later, but no UI ships for it.
- Conversation/thread grouping in the list. Both existing clients are flat; threading data powers replies only.
- PGP or S/MIME. Tracked separately in [`docs/tentative/apple-smime.md`](../tentative/apple-smime.md).
- Any direct IMAP or SMTP transport.

---

## Prerequisites

- Rust toolchain (`rustup`), `gtk4`, `libadwaita`, `webkitgtk-6.0` development packages. On the Arch development host these are `gtk4`, `libadwaita`, `webkitgtk-6.0` — the first two are already installed; `webkitgtk-6.0` is in `extra`.
- `blueprint-compiler` for `.blp` sources.
- `node` / `npm` for `scripts/sync-vendored.sh` in a developer checkout (not needed by `makepkg`).
- Podman or Docker for the packaging and smoke targets.
- A stage-environment account for fixture capture and end-to-end verification.
- No new AWS resources, no Terraform changes, no new Lambdas.

---

## Open questions

1. **Changelog prefix.** The `Apple:` prefix exists because `set-testflight-notes.py` filters on it. There is no equivalent consumer for Linux yet. Adopt `Linux:` now in anticipation of generated release notes for the packages, or leave fragments unprefixed until something consumes them? A `linux-changelog.yml` gate mirroring `apple-changelog.yml` only makes sense once the answer is "adopt".
2. **Web Push ownership.** The 1.2.x browser extension will need the same `push_register` platform discriminator and VAPID transport. Should that land as shared groundwork in 1.1.x, or wait for 1.2.x and leave Linux polling for a release?
3. **RHEL 9.** Confirmed unsupportable from distro dependencies. Is RHEL 10 / Fedora an acceptable reading of "RHEL to follow", or does RHEL 9 need to be met — which would mean adopting Flatpak?
4. **AUR publication.** Which account owns the AUR package, and does the repo carry the `.SRCINFO` or generate it at publish time?
5. **Recipient autocomplete source.** Apple reads the system Contacts store. Sent-message history is the proposed substitute; is an optional `libebook` (Evolution Data Server) integration worth the dependency on GNOME systems?
6. **Dropping GSettings.** The Configuration model replaces dconf with TOML plus `$XDG_STATE_HOME`, which departs from GNOME convention and means the app won't appear in `dconf-editor` or be manageable by the GSettings-based fleet tooling some organizations use. The plan judges one config system better than two. Confirm that trade before Phase 1, since reversing it later means migrating users' files.
7. **Per-key `updated_at` on the preferences row.** *(Raised by the resolution of the config-file question — see Configuration model.)* The row has no timestamp or version attribute, so a client cannot tell whether its local edit or the server's value is newer. The consequence is bounded but real: an offline `config.toml` edit loses to a concurrent edit from another device on the next foreground pull. Fixing it means adding a per-key `updated_at` in `set_preferences` and comparing on pull — a server change affecting the Apple and web clients too. Out of scope for 1.1.0 and documented in `cabalmail.5` as a known edge; confirm that's acceptable, or schedule the server work.
8. **Blueprint vs plain `.ui`.** Blueprint is materially nicer to review but adds a build-time dependency that must be present in all three packaging containers. Confirm it packages cleanly in Phase 2, and fall back to `.ui` XML if not.

---

## Sources

- [Repology: webkitgtk packages by distribution](https://repology.org/project/webkitgtk/packages)
- [WebKitGTK API Versions Demystified — Michael Catanzaro](https://blogs.gnome.org/mcatanzaro/2025/04/28/webkitgtk-api-versions/)
- [Ubuntu 24.04 (noble): libadwaita-1-0 1.4.0](https://answers.launchpad.net/ubuntu/noble/amd64/libadwaita-1-0/1.4.0-1ubuntu1)
- [Ubuntu 24.04 (noble): libgtk-4-dev](https://packages.ubuntu.com/noble/libgtk-4-dev)

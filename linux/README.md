# Cabalmail Linux Client

A native GTK4 + libadwaita desktop client, packaged first for Arch (AUR) and,
from Phase 8, for Debian/Ubuntu and Fedora/RHEL 10. The design, the phase plan,
and the rationale behind every stack decision live in
[`docs/1.1.x/linux-client-plan.md`](../docs/1.1.x/linux-client-plan.md).

Like the Apple client, this client talks only to the existing Lambda API — no
IMAP library, no SMTP transport.

## Layout

| Path | What it is |
| --- | --- |
| `cabalmail-kit/` | Library crate: config, auth, API client, models, MIME, caches, compose, outbox, policy. **No GTK, libadwaita, or WebKit dependency**, so its tests run with no display server. |
| `cabalmail-gtk/` | The application. Builds the `cabalmail` binary. |
| `xtask/` | `cargo xtask …` — build, packaging, and CI automation. |
| `scripts/` | Shell helpers the xtask subcommands wrap. |
| `packaging/` | Distribution packaging (Arch first; Debian and RPM in Phase 8). |

## Toolchain

Install **`rustup`, not the distro `rust` package**. On Arch the two conflict
(`rustup` declares `Provides: rust cargo rustfmt`), and only rustup honours
`rust-toolchain.toml` — with the distro package you silently build with whatever
Arch ships rather than the pinned toolchain.

```sh
sudo pacman -S rustup podman gtk4 libadwaita webkitgtk-6.0 blueprint-compiler
rustup toolchain install 1.97.1 --profile minimal -c clippy -c rustfmt -c llvm-tools
```

`rust-toolchain.toml` pins **1.97.1 exactly**, not `stable`: CI runs
`clippy -D warnings`, so a floating channel would let a new Rust release redden
CI overnight on lints nobody wrote code against. Bumping it is a deliberate PR.

`Cargo.lock` is committed — distro packaging builds offline against vendored
crates, which needs a lock.

Those packages ship their headers in the main package on Arch; there is no
`-dev` split. `nodejs`/`npm` join the list once the composer's vendored
JavaScript arrives (Phase 5).

`blueprint-compiler` is not optional: the interface is written in Blueprint and
compiled to GtkBuilder XML by `cabalmail-gtk/build.rs`, which fails loudly and
names the package if the compiler is missing rather than falling back to a
second UI format.

## Build and test

```sh
cargo build --workspace
cargo test -p cabalmail-kit      # no display server, no network
cargo test -p cabalmail-gtk      # widget tests skip without a display; CI uses xvfb-run
cargo test -p xtask              # workspace shape, schema/Lambda drift, generated docs
cargo run -p cabalmail-gtk
cargo xtask ci                   # what CI runs, in CI's order — run before every push
```

## Tasks

`cargo xtask` is the one spelling of each build operation, shared by humans and
by the workflow, so neither can drift from the other:

| Subcommand | What it does |
| --- | --- |
| `cargo xtask ci` | `cargo fmt --check`, `clippy -D warnings`, kit tests, workspace checks, app tests — in that order, stopping at the first failure. Wraps the app tests in `xvfb-run` when there is no session to use. |
| `cargo xtask sync-vendored` | Materializes marked and turndown into `cabalmail-gtk/resources/editor/` from `react/admin/node_modules`, running `npm ci` first if needed. Needs node and npm; the files it writes are gitignored. Wraps [`scripts/sync-vendored.sh`](scripts/sync-vendored.sh), the sibling of `apple/scripts/sync-vendored.sh`. |
| `cargo xtask package <distro>` | Declared; lands with Arch packaging in Phase 2. |
| `cargo xtask smoke` | Declared; lands with the test harness in Phase 2. |
| `cargo xtask fixtures` | Declared; lands with the HTTP contract fixtures in Phase 2. |

The three that have not landed answer with the work item that implements them
rather than with "unknown subcommand" — the vocabulary is fixed now so the
plan, the workflow, and this README can name an operation before it exists.

`react/admin/package.json` holds the marked and turndown version pins for all
three clients, which is what keeps the Linux composer inside Dependabot's
reach. `makepkg` does not run `sync-vendored`: the PKGBUILD fetches the same
upstream tarballs as pinned `source=()` entries, because `prepare()` must not
reach the network (Phase 2).

The app is built against **GTK 4.14 and libadwaita 1.4** — Ubuntu 24.04's
versions — through the `v4_14` and `v1_4` crate features, so newer API fails to
compile here rather than in a packaging container months later. Raising those
features is a deliberate decision about which distros the client still supports,
not a fix for a call site that will not build.

`cargo test -p xtask` is where the checks that reach outside the workspace live:
that the toolchain pin is exact, that the client's synced-preference keys match
`lambda/api/set_preferences/function.py`'s `APP_ALLOWED` (a divergence would
400 on every push at runtime), and that the generated documentation is current.
After changing the configuration schema, regenerate the two committed files it
drives:

```sh
CABALMAIL_UPDATE_DOCS=1 cargo test -p xtask
```

## Configuration

Settings live in `$XDG_CONFIG_HOME/cabalmail/config.toml`, hand-editable, with
three sections that say how far each value travels: `[preferences]` syncs to
every device, `[preferences.linux]` to this user's other Linux machines, and
`[local]` nowhere. Flags and `CABALMAIL_*` variables override for one run
without touching the file or the server.

```sh
cabalmail --print-config                       # values and where each came from
cabalmail config set dispose_action trash
cabalmail config reset dispose_action
```

Full reference: `cabalmail-gtk/data/cabalmail.5.md` (installed as
`man 5 cabalmail`) and `cabalmail-gtk/data/config.example.toml`. Both are
generated from the key table in `cabalmail-kit/src/config/schema.rs`.

## Status

Phase 1 is complete. The workspace scaffolding (work item 1), the
`cabalmail-kit` skeleton — module stubs and the `CabalmailError` taxonomy (work
item 2) — the layered configuration store with its CLI (work item 3), the GTK
application shell (work item 4), and the `xtask` entry points (work item 5) are
in place. `cargo run -p cabalmail-gtk` opens a window; there is nothing to sign
in to yet, which is Phase 3.

Next is Phase 2: the `linux.yml` workflow, Arch packaging, and the contract-test
harness — which is also what fills in `cargo xtask package`, `smoke`, and
`fixtures`.

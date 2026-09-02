# Cabalmail Linux Client

A native GTK4 + libadwaita desktop client, packaged first for Arch (AUR) and,
from Phase 8, for Debian/Ubuntu and Fedora/RHEL 10. The design, the phase plan,
and the rationale behind every stack decision live in
[`docs/1.x/linux-client-plan.md`](../docs/1.x/linux-client-plan.md).

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

Building the *package* needs more than building the source tree does —
`glib2-devel`, `go-md2man`, and `namcap`. Those come from
[`packaging/deps/arch.txt`](packaging/deps/arch.txt), which is also where the
PKGBUILD's dependency arrays come from:

```sh
grep -vE '^\s*(#|$)' packaging/deps/arch.txt | sudo pacman -S --needed -
```

## Build and test

```sh
cargo build --workspace
cargo test -p cabalmail-kit      # no display server, no network
cargo test -p cabalmail-gtk      # widget tests skip without a display; CI uses xvfb-run
cargo test -p xtask              # workspace shape, schema/Lambda drift, generated docs
cargo run -p cabalmail-gtk
cargo xtask ci                   # what CI runs, in CI's order — run before every push
```

`cargo test -p xtask` also asserts that `cabalmail-kit` reaches no GTK,
libadwaita, or WebKit crate at any depth. That is the property that lets its
tests run on a bare runner with no display, and the one a new transitive
dependency can take away without anyone typing it.

## Tasks

`cargo xtask` is the one spelling of each build operation, shared by humans and
by the workflow, so neither can drift from the other:

| Subcommand | What it does |
| --- | --- |
| `cargo xtask ci` | `cargo fmt --check`, `clippy -D warnings`, kit tests, workspace checks, app tests — in that order, stopping at the first failure. Wraps the app tests in `xvfb-run` when there is no session to use. `--step <name>` runs one of them, which is how each CI job runs exactly one; `--list` prints the names. |
| `cargo xtask sync-vendored` | Materializes marked and turndown into `cabalmail-gtk/resources/editor/` from `react/admin/node_modules`, running `npm ci` first if needed. Needs node and npm; the files it writes are gitignored. Wraps [`scripts/sync-vendored.sh`](scripts/sync-vendored.sh), the sibling of `apple/scripts/sync-vendored.sh`. |
| `cargo xtask package arch` | Builds the Arch package from the working tree and lints it with `namcap`. Stages a copy of [`packaging/arch/PKGBUILD`](packaging/arch/PKGBUILD) with `pkgver` taken from `git describe` and the git source pointed at the local checkout, then runs `makepkg`. Needs an Arch machine with `packaging/deps/arch.txt` installed, and refuses to run as root, as makepkg does. `deb` and `rpm` name their Phase 8 work item. |
| `cargo xtask smoke` | Declared; lands with the test harness in Phase 2. |
| `cargo xtask fixtures` | Declared; lands with the HTTP contract fixtures in Phase 2. |

The two that have not landed answer with the work item that implements them
rather than with "unknown subcommand" — the vocabulary is fixed now so the
plan, the workflow, and this README can name an operation before it exists.

makepkg builds from git, so `cargo xtask package arch` packages `HEAD`: an
uncommitted change is not in the package, and the run says so before it starts.
The version it stamps is `<latest tag>.r<commits since>.g<object>`, which pacman
orders after the tag it came from. The `pkgver` committed in the PKGBUILD is the
one an AUR publication carries; a release bumps it.

`react/admin/package.json` holds the marked and turndown version pins for all
three clients, which is what keeps the Linux composer inside Dependabot's
reach. `makepkg` does not run `sync-vendored`: npm is not a build dependency of
the package, so the PKGBUILD fetches the same upstream tarballs as pinned,
checksummed `source=()` entries and a test fails if those pins drift from
React's lockfile.

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

## Continuous integration

[`.github/workflows/linux.yml`](../.github/workflows/linux.yml) runs on pushes
to `main` and `stage` under `linux/**`, and on demand. Each job runs one step of
`cargo xtask ci`, named with `--step`, so CI runs the same commands as the
pre-push gate and a failure names itself:

| Job | Step | Where |
| --- | --- | --- |
| `lint` | `format` | `ubuntu-latest` — `cargo fmt` parses rather than compiles, so it needs nothing installed |
| `kit-test` | `kit-tests` | `ubuntu-latest` — no display, no network, no GUI dependency |
| `workspace-checks` | `workspace-checks` | `ubuntu-latest` — the checks that reach outside the workspace, including the Lambda contract |
| `app-build` | `clippy` | `ubuntu:24.04` container — the API floor |
| `app-test` | `app-tests` | `ubuntu:24.04` container, under Xvfb |
| `package-arch` | — | `archlinux:base-devel` container — `cargo xtask package arch` as an unprivileged build user |

`app-build` runs clippy rather than a build of its own: `clippy --workspace
--all-targets` is a full compile, so building against the floor and linting are
the same work. A call needing GTK 4.16 therefore fails `app-build` and leaves
`lint` green.

Every step but `format` passes `--locked`: `Cargo.lock` is committed because
distro packaging builds offline against vendored crates, so a dependency bump
whose lock update was never committed has to fail in CI rather than resolve
silently there and fail in `makepkg`.

`package-arch` is the exception to one-job-one-step: packaging needs an Arch
container and several minutes, which no developer should pay for on every
pre-push gate, so it runs `cargo xtask package arch` instead. It is also the
only job that builds what a user installs rather than what a developer builds —
`makepkg` clones the checkout, builds it offline against the committed lock,
runs the kit tests inside `check()`, and `namcap` lints both the PKGBUILD and
the package.

System packages come from [`packaging/deps/ubuntu.txt`](packaging/deps/ubuntu.txt)
and [`packaging/deps/arch.txt`](packaging/deps/arch.txt) — one list per
distribution, read by the CI containers now, by the PKGBUILD's dependency
arrays (a test holds them to the list), and by the Debian packaging in Phase
8. `xtask/tests/workflow_contract.rs` holds the pieces together: a step with no
job, a job naming a step that does not exist, a job spelling its own `cargo`
command, a floor step that escaped the container, or a file a job reaches for
that is missing from the workflow's `paths:` filter all fail there rather than
passing quietly.

The same applies to files the *tests* read from outside `linux/` — the Lambda
handler behind the preferences contract, React's lockfile behind the PKGBUILD's
JavaScript pins. A check over a file this workflow does not fire on reports its
drift on the next unrelated push, long after the change that caused it merged.
Those files are registered in [`xtask/tests/support/mod.rs`](xtask/tests/support/mod.rs)
and read through `repo_input`, which refuses an unregistered path; the workflow
contract fails if a registered one is missing from either gate's filter — this
workflow's `paths:`, or the `rust` filter in
[`lint.yml`](../.github/workflows/lint.yml), which runs the same
`cargo xtask ci` on pull requests.

The packaged-artifact smoke test, coverage, and the `cargo-deny`/dependency-tree
guards are the remaining Phase 2 work items; the workflow names the item that
owns each.

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

Arch packaging is finished but **not published**: the AUR is closed to new
account registrations, so there is no route to publish the package. It is built
and linted on every push regardless, which is what keeps it working.

Phase 2 is under way. The `linux.yml` workflow (work item 1) is in place, so
every push to a named branch is gated on the same steps a developer runs, and
Arch packaging (work item 4) builds and lints an installable package on every
push. Still to come: the contract-test harness and fixtures (item 3), release
artifacts (item 5), and the guard rails (item 6) — which together fill in
`cargo xtask smoke` and `fixtures`. The remaining pinning of work item 2 — the
coverage, licence, and advisory tools — lands with the jobs that run them.

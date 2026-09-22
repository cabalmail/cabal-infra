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

Two of the gate's steps run a binary that is not part of the toolchain: the
coverage floor over `cabalmail-kit`, and the dependency-graph check against
[`deny.toml`](deny.toml).

```sh
cargo install --locked cargo-llvm-cov@0.9.1
cargo install --locked cargo-deny@0.20.2
```

Without one, `cargo xtask ci` says so and runs everything else. CI installs the
same pinned versions and treats a missing one as a failure, so neither check is
skipped where it counts.

## Build and test

```sh
cargo build --workspace
cargo test -p cabalmail-kit      # no display server, no network
cargo test -p cabalmail-gtk      # widget tests skip without a display; CI uses xvfb-run
cargo test -p xtask              # workspace shape, schema/Lambda drift, generated docs
cargo run -p cabalmail-gtk
cargo xtask ci                   # what CI runs, in CI's order — run before every push
```

`cargo xtask smoke` installs into the root filesystem, so run it in a throwaway
container rather than on your own machine. From the repository root, after
`cargo xtask package arch`:

```sh
podman run --rm -v "$PWD:/repo:ro" -w /repo/linux archlinux:base-devel bash -c '
  pacman -Syu --needed --noconfirm rustup xorg-server-xvfb xorg-xauth
  rustup toolchain install --profile minimal 1.97.1
  export PATH="$HOME/.cargo/bin:$PATH" CARGO_TARGET_DIR=/tmp/t
  cargo +1.97.1 run --locked -q -p xtask -- smoke target/package/arch
'
```

```
[xtask] smoke: /usr/bin/cabalmail
cabalmail: self-test reached a main window
[xtask] smoke: target/package/arch/cabalmail-…-x86_64.pkg.tar.zst started and drew a window
```

The checkout is mounted read-only, which is why nothing `smoke` writes lives
under it. `docker` works the same way.

`cargo test -p xtask` also asserts that `cabalmail-kit` reaches no GTK,
libadwaita, or WebKit crate at any depth. That is the property that lets its
tests run on a bare runner with no display, and the one a new transitive
dependency can take away without anyone typing it.

## Tasks

`cargo xtask` is the one spelling of each build operation, shared by humans and
by the workflow, so neither can drift from the other:

| Subcommand | What it does |
| --- | --- |
| `cargo xtask ci` | `cargo fmt --check`, `clippy -D warnings`, kit tests, workspace checks, app tests, the kit's coverage floor, `cargo deny check` — in that order, stopping at the first failure. Wraps the app tests in `xvfb-run` when there is no session to use. `--step <name>` runs one of them, which is how each CI job runs exactly one; `--list` prints the names. |
| `cargo xtask sync-vendored` | Materializes marked and turndown into `cabalmail-gtk/resources/editor/` from `react/admin/node_modules`, running `npm ci` first if needed. Needs node and npm; the files it writes are gitignored. Wraps [`scripts/sync-vendored.sh`](scripts/sync-vendored.sh), the sibling of `apple/scripts/sync-vendored.sh`. |
| `cargo xtask package arch` | Builds the Arch package from the working tree and lints it with `namcap`. Stages a copy of [`packaging/arch/PKGBUILD`](packaging/arch/PKGBUILD) with `pkgver` taken from `git describe` and the git source pointed at the local checkout, then runs `makepkg`. Needs an Arch machine with `packaging/deps/arch.txt` installed, and refuses to run as root, as makepkg does. `deb` and `rpm` name their Phase 8 work item. |
| `cargo xtask smoke` | Installs a built package and launches what it installed, asserting the client reaches a main window. The only check over the packaged artifact rather than the source tree. Takes the package to install, or a directory holding one, or uses the one `package arch` last built. Needs root, since it installs into the root filesystem — meant for a throwaway container, not a developer's machine (see below). |
| `cargo xtask fixtures` | Declared; lands with the API client in Phase 3. |

The one that has not landed answers with the work item that implements it
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
| `supply-chain` | `supply-chain` | `ubuntu-latest` — `cargo-deny`; the one job that can redden without anything here changing |
| `coverage` | `coverage` | `ubuntu-latest` — `cargo-llvm-cov` over the kit, against the line floor |
| `package-arch` | — | `archlinux:base-devel` container — `cargo xtask package arch` as an unprivileged build user, uploading the package and its `.SRCINFO` |
| `smoke` | — | `archlinux:base-devel` container — installs that package and runs `cargo xtask smoke` under Xvfb |

`app-build` runs clippy rather than a build of its own: `clippy --workspace
--all-targets` is a full compile, so building against the floor and linting are
the same work. A call needing GTK 4.16 therefore fails `app-build` and leaves
`lint` green.

Every step but `format` passes `--locked`: `Cargo.lock` is committed because
distro packaging builds offline against vendored crates, so a dependency bump
whose lock update was never committed has to fail in CI rather than resolve
silently there and fail in `makepkg`.

`package-arch` and `smoke` are the exceptions to one-job-one-step: packaging
needs an Arch container and several minutes, and installing a package into the
root filesystem is not something to do on a pre-push gate, so neither belongs in
`cargo xtask ci`. They are the two jobs that handle what a user installs rather
than what a developer builds — `makepkg` clones the checkout, builds it offline
against the committed lock, runs the kit tests inside `check()`, and `namcap`
lints both the PKGBUILD and the package; then `smoke` installs the result into a
clean container and launches it. A GResource that never got bundled, a data file
the package forgot to install, or a shared library missing from the dependency
array fails there and in no other job.

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

The HTTP contract fixtures are the one part of the test harness still to come:
there is no API client to decode a captured response into until Phase 3, so
`cargo xtask fixtures` names that work item rather than capturing anything.

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

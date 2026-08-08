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
| `packaging/` | Distribution packaging (Arch first; Debian and RPM in Phase 8). |

## Toolchain

Install **`rustup`, not the distro `rust` package**. On Arch the two conflict
(`rustup` declares `Provides: rust cargo rustfmt`), and only rustup honours
`rust-toolchain.toml` — with the distro package you silently build with whatever
Arch ships rather than the pinned toolchain.

```sh
sudo pacman -S rustup podman webkitgtk-6.0
rustup toolchain install 1.97.1 --profile minimal -c clippy -c rustfmt -c llvm-tools
```

`rust-toolchain.toml` pins **1.97.1 exactly**, not `stable`: CI runs
`clippy -D warnings`, so a floating channel would let a new Rust release redden
CI overnight on lints nobody wrote code against. Bumping it is a deliberate PR.

`Cargo.lock` is committed — distro packaging builds offline against vendored
crates, which needs a lock.

Other build dependencies (`gtk4`, `libadwaita`, `blueprint-compiler`, and
`nodejs`/`npm` for the vendored composer JS in a developer checkout) ship
headers in the main packages on Arch; there is no `-dev` split.

## Build and test

```sh
cargo build --workspace
cargo test -p cabalmail-kit      # no display server, no network
cargo run -p cabalmail-gtk
cargo xtask ci                   # what CI runs, in CI's order
```

## Status

Phase 1 is in progress. The workspace scaffolding (work item 1) and the
`cabalmail-kit` skeleton — module stubs and the `CabalmailError` taxonomy (work
item 2) — are in place. The layered configuration store, the GTK application
shell, and the `xtask` subcommand implementations follow in work items 3
through 5; CI and Arch packaging in Phase 2.

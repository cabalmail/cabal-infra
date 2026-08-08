- **Cargo workspace for the native Linux client.** `linux/` holds a three-crate
  workspace — `cabalmail-kit` (the GUI-free core), `cabalmail-gtk` (the
  application, which builds the `cabalmail` binary), and `xtask` (build and
  packaging automation) — with the Rust toolchain pinned to an exact 1.97.1,
  edition 2024, a committed `Cargo.lock` for offline distro packaging, and
  shared rustfmt and clippy configuration. No user-facing functionality yet;
  this is the scaffolding the rest of the client is built through. See
  [`docs/1.1.x/linux-client-plan.md`](docs/1.1.x/linux-client-plan.md).

- **Test harness for the Linux client.** `cabalmail-kit` gained eight pure
  policy modules — split-view collapse, reader toolbar and header sizing, list
  row identity, compose-cancel resolution, Archive/Trash/Restore per folder,
  received-HTML rewriting, filter-pill counts, and cross-folder search source
  — each taking the fields it decides on rather than a model, so the UI
  decisions are testable with no display server. `cargo xtask ci` gained a
  `coverage` step enforcing a line floor over the kit with `cargo-llvm-cov`,
  and `cargo xtask smoke` installs the built Arch package into a clean
  container and launches it, asserting the installed binary reaches a main
  window via a new `cabalmail --self-test`. `package-arch` now uploads the
  package and a generated `.SRCINFO` as workflow artifacts, which is what
  `smoke` installs.

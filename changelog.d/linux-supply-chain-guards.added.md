- **Licence and advisory gate for the Linux client.** `cargo xtask ci` gained a
  `supply-chain` step running `cargo deny check` against a new
  `linux/deny.toml`, with its own job in `linux.yml` and in the pull-request
  gate. A test fails if the two workflows, the task runner, and the README stop
  naming one pinned version of `cargo-deny`. The kit's freedom from GTK,
  libadwaita, GDK, GSK, and WebKit is now asserted transitively against the
  resolved dependency tree, not just against its manifest.

- **Rust in the pull-request lint gate.** The `Lint` workflow now runs
  `cargo xtask ci` — rustfmt, clippy `-D warnings`, the kit and repo-shape
  tests, and the widget tests under xvfb — for PRs touching `linux/**`, on
  Ubuntu 24.04 (the GTK 4.14 / libadwaita 1.4 API floor). Edits to
  `lambda/api/set_preferences/function.py` trigger it too, so a
  preference-key divergence between the Lambda and the Linux client fails
  at review time rather than as a 400 at runtime.

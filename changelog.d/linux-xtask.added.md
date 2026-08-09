- **Task runner for the Linux client.** `cargo xtask ci` runs what CI runs, in
  CI's order — `cargo fmt --check`, `clippy -D warnings`, kit tests, workspace
  checks, app tests — stopping at the first failure and repeating the command
  so it can be re-run by hand, and reaching for `xvfb-run` only when there is no
  session for the widget tests to use. The step list lives in one place, so the
  pre-push gate and the workflow that lands in Phase 2 cannot drift apart.
  `cargo xtask sync-vendored` materializes the composer's marked and turndown
  bundles from `react/admin/node_modules`, which stays the single source of
  their version pins across the React, Apple, and Linux clients; the bytes are
  gitignored, and a test fails if a file is added to the script without an
  ignore line. `package`, `smoke`, and `fixtures` are declared rather than
  omitted — asking for one names the work item that implements it — so the plan
  and the workflow can spell an operation before it exists. See
  [`docs/1.1.x/linux-client-plan.md`](docs/1.1.x/linux-client-plan.md).

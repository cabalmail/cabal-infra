- **CI for the Linux client.** `linux.yml` gates every push to `main` and
  `stage` under `linux/**`, running one `cargo xtask ci` step per job so the
  workflow and the pre-push gate run the same commands: formatting, the kit
  tests, the workspace and Lambda-contract checks, and — inside an
  `ubuntu:24.04` container — the workspace build and the widget tests under
  Xvfb. The container is what enforces the GTK 4.14 API floor on every push
  rather than at packaging time, and the job asserts the version it got. A
  test fails the build if a step has no job, a job names a step that does not
  exist, a job spells a `cargo` command of its own, or a file a job reaches for
  is missing from the workflow's path filter. See
  [`docs/1.1.x/linux-client-plan.md`](docs/1.1.x/linux-client-plan.md).

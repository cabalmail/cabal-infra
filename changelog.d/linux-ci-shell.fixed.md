- **Linux CI ran its container steps under the wrong shell.** `linux.yml` now
  declares `bash` as its run default. The runner falls back to `sh` where it is
  not told otherwise, and the `ubuntu:24.04` container's `sh` rejects
  `set -o pipefail`, so the API-floor build and the widget tests failed on every
  run of that workflow since it landed. The path filters of both gates that run
  `cargo xtask ci` — `linux.yml` on a push, `lint.yml`'s `rust` job on a pull
  request — now also cover every file those tests read from outside `linux/`,
  and a test fails if one is registered but missing from either.

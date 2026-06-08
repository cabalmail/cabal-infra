- Changelog fragments and a release-promotion script. Unreleased entries are
  now added as individual files under `changelog.d/` (named
  `<slug>.<category>.md`) instead of editing `CHANGELOG.md` directly, so
  concurrent branches and Claude Code sessions no longer collide on a shared
  `## [Unreleased]` block or need to renumber when a release lands in between.
  `.github/scripts/collate-changelog.sh` folds all pending fragments into a
  dated section at release time, and `.github/scripts/promote.sh` (also
  `make promote VERSION=<x.y.z>`) collates, commits on `stage`, pushes, and
  opens the `stage -> main` PR, leaving the merge to prod as a manual step. See
  `changelog.d/README.md` and `docs/releasing.md`.

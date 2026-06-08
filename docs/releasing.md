# Releasing (promoting stage to prod)

Cabalmail promotes to prod by merging `stage` into `main` (`main` = prod, and
is protected: PR-only). The changelog is assembled from fragments at release
time; see [`changelog.d/README.md`](../changelog.d/README.md) for how to add
entries during development.

## Cut a release

From a clean `stage` work tree:

```sh
make promote VERSION=0.10.14
# or a bump keyword computed from the latest tag:
make promote VERSION=patch          # also: minor, major
# or call the script directly:
./.github/scripts/promote.sh 0.10.14
```

This will:

1. Collate every pending `changelog.d/*.md` fragment into a new
   `## [VERSION] - <today>` section at the top of `CHANGELOG.md`, and delete the
   fragments.
2. Show you the staged diff and ask for confirmation.
3. Commit on `stage` (`Set release date for version VERSION`), push `stage`,
   and open the `stage -> main` PR.
4. Watch the PR checks and report.

Merging the PR is left to you - promotion to prod stays a deliberate manual
step.

### Flags

- `--no-push` - collate and commit locally only; inspect, then push yourself.
- `--yes` - skip the confirmation prompt.
- `--date YYYY-MM-DD` - override the release date.

## GitHub release (automatic)

Once the `stage -> main` PR merges, the `release.yml` workflow
([`.github/workflows/release.yml`](../.github/workflows/release.yml)) runs on
the push to `main`: it reads the top `## [X.Y.Z]` section of `CHANGELOG.md` and,
if no GitHub release for that version exists yet, tags the merge commit and
publishes a release whose notes are that version's changelog section, header and
all (extracted by `.github/scripts/changelog-section.sh`). There is no manual
release step - merge the PR and the release appears.

It is idempotent: a push that introduces no new top version, or whose version
is already released, does nothing, and it only runs when `CHANGELOG.md` changed.
To (re)create a release for a specific version by hand, trigger the workflow via
`workflow_dispatch` with a `version` input.

## In-flight sessions

Because pending work lives in `changelog.d/` and not in `CHANGELOG.md`, a branch
or Claude Code session open across a release no longer needs renumbering. After
the release merges, pull `stage`/`main`: the released fragments are gone, your
own fragment is untouched, and it rolls into the next release.

## One-time transition

The fragment system expects a `CHANGELOG.md` whose top entry is a *dated*
release - no `## [Unreleased]` section. If a branch still carries a hand-written
`## [Unreleased]` (or a pre-numbered, not-yet-released) section when this lands,
retire it one of two ways:

- **Ship it the old way first:** date-stamp that section and release it so the
  top of `CHANGELOG.md` is dated; fragments then govern everything after, or
- **Convert it:** move each of its bullets into a
  `changelog.d/<slug>.<category>.md` fragment and delete the section, so it
  collates into the next release.

Either leaves the invariant the collator relies on: `CHANGELOG.md` holds only
dated sections, and all pending entries live in `changelog.d/`.

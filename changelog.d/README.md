# Changelog fragments

Pending changelog entries live here as individual files instead of being
written straight into `CHANGELOG.md`. At release time they are collated into a
new dated section and deleted.

## Why

Multiple in-flight branches (and concurrent Claude Code sessions) used to edit
the same `## [Unreleased]` block of `CHANGELOG.md`. That produced merge
conflicts, and whenever a release landed in between, every in-flight entry was
suddenly pointing at a version that had already shipped and had to be
renumbered by hand. A fragment is a standalone file, so concurrent work never
touches `CHANGELOG.md` and never needs to know the target version: at release
time every pending fragment rolls into the new section automatically.

## Adding an entry

Create a file named `<slug>.<category>.md`:

- `<slug>` - a short kebab-case description, unique enough to avoid collisions
  (e.g. `imap-maintenance-flag`, `send-idempotency`).
- `<category>` - one of the Keep a Changelog sections, lower-case:
  `added`, `changed`, `deprecated`, `removed`, `fixed`, `security`.

The file body is the entry exactly as it should appear under that section,
including the leading `- ` and any continuation-line indentation. Match the
surrounding house style (hard-wrapped, two-space continuation indent). One
fragment is one bullet.

Example - `changelog.d/send-idempotency.added.md`:

    - `/send` is now idempotent against client retries. It claims the
      Message-Id in `cabal-rate-limits` before SMTP and releases it on
      failure, so a retried send reports success without re-delivering.

Do **not** edit `CHANGELOG.md` directly for unreleased work, and do not create
an `## [Unreleased]` section - the collator owns the top of that file. Record
only what shipped to users: no fragment for a bug introduced and fixed within
the same unreleased cycle, or a latent bug fixed before exposure.

## Releasing

`.github/scripts/promote.sh` (or `make promote VERSION=<x.y.z>`) runs the
collation as part of cutting a release. To preview locally without releasing:

    ./.github/scripts/collate-changelog.sh <version>

That folds the fragments into `CHANGELOG.md`, deletes them, and stages the
result for inspection. See [`docs/releasing.md`](../docs/releasing.md) for the
full promotion flow.

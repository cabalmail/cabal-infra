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

## Apple client entries

Any fragment describing a change to the Apple clients (`apple/Cabalmail`,
`apple/CabalmailMac`, `apple/CabalmailKit/Sources`) must prefix its entry with
`Apple:`, right after the leading `- `:

    - Apple: **Threaded reader.** Messages now group into conversation
      threads in the reader pane.

The TestFlight "What to Test" notes are built from the released `CHANGELOG.md`
section by `.github/scripts/set-testflight-notes.py`, which keeps only the
`Apple:`-prefixed entries (stripping the prefix, since it is redundant inside
an Apple app) and drops everything else. So an Apple-client change without the
prefix silently disappears from the notes testers see.

A PR that touches the Apple client sources fails the
`.github/workflows/apple-changelog.yml` check unless it adds such a fragment.
For a genuinely non-user-facing Apple change (refactor, test-only, CI,
xcodegen), apply the `no-changelog` label to the PR to opt out.

## Android client entries

Likewise, any fragment describing a change to the Android client
(`android/app/src/main`, `android/kit/src/main`) must prefix its entry with
`Android:`, and the bold headline must not repeat the word "Android" - the
prefix already says it, and the collated changelog reads
`- Android: **Compose with on-the-fly From.**`, not `**Android compose ...**`.

The Play Console release notes are built from the released `CHANGELOG.md`
section by `.github/scripts/play-release-notes.py` on the prod upload. Google
Play caps release notes at **500 characters** for the whole release, so, unlike
TestFlight, **only the bold headline of each `Android:` entry survives** - the
body never reaches testers. The notes lead with "See CHANGELOG.md for
details." and then list the headlines under their category, so write the
headline as the one line a tester will read on its own: a concrete
noun-phrase, roughly 40 characters, no phase numbers or internal jargon (put
those in the body). Every Android headline in a release shares that 500-char
budget; if it overruns, whole trailing headlines are dropped with a CI
warning. `scripts/tests/test_play_release_notes.py` renders the pending
fragments and fails the PR when the pending set no longer fits - trim
headlines, not bodies.

A PR that touches the Android client sources fails the
`.github/workflows/android-changelog.yml` check unless it adds such a
fragment; opt out with the `no-changelog` label as for Apple.

## Releasing

`scripts/promote.sh` (or `make promote VERSION=<x.y.z>`) runs the
collation as part of cutting a release. To preview locally without releasing:

    ./scripts/collate-changelog.sh <version>

That folds the fragments into `CHANGELOG.md`, deletes them, and stages the
result for inspection. See [`docs/releasing.md`](../docs/releasing.md) for the
full promotion flow.

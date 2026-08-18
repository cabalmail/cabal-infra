- **Play Console release notes from the changelog.** The prod Android upload
  in `android.yml` now writes release notes for gradle-play-publisher from
  the released `CHANGELOG.md` section: the bold headline of every
  `Android:`-prefixed entry, grouped by category under a "See CHANGELOG.md
  for details." lead, trimmed on whole lines to Google Play's 500-character
  cap (`.github/scripts/play-release-notes.py`). The `Android:` prefix is
  the Android counterpart of `Apple:` - a new `android-changelog.yml` gate
  requires it on PRs touching the client sources (both gates now share
  `check-client-changelog.sh`), and `scripts-tests.yml` fails a PR whose
  pending Android headlines no longer fit the budget.

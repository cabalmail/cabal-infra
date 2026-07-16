- **Apple changelog gate no longer blocks release PRs.** The
  `apple-changelog` check now accepts an `Apple:`-prefixed entry added to
  `CHANGELOG.md` as equivalent to a `changelog.d/` fragment, so a stage->main
  release PR (whose fragments have already been collated into `CHANGELOG.md`
  and deleted) passes without needing the `no-changelog` opt-out. Apple
  changes with no note anywhere still fail.

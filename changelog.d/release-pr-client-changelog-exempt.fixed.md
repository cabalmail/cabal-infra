- **Release PRs no longer carry a cancelled changelog check.** `promote.sh`
  labelled the `stage` -> `main` PR `no-changelog` seconds after opening it;
  the `labeled` event re-ran the Apple and Android changelog gates, cancelling
  the run the PR's opening had started, and the cancelled check stayed on the
  head commit, where the release dashboard counted it as failing and held the
  merge. The label step is gone. `check-client-changelog.sh` now skips a
  release PR by its branch names instead, as `check-changelog-fragment.sh`
  already did, which also retires its fallback of looking for an
  `Apple:`/`Android:` line added to `CHANGELOG.md`.

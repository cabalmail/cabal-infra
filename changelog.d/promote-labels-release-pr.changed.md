- **Release PRs are labelled `no-changelog` by `make promote`.**
  `promote.sh` now adds the label to the `stage` -> `main` PR it opens (or
  finds already open). The Apple and Android changelog gates passed a release
  PR only when the collated `CHANGELOG.md` gained an `Apple:`/`Android:` line,
  so a release whose only client changes each shipped under `no-changelog`
  failed until someone added the label by hand. A failed label call is a
  warning, not a failed release.

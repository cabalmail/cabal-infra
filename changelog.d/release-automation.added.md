- GitHub releases are now created automatically on merge to `main`. The new
  `release.yml` workflow reads the freshly promoted top section of
  `CHANGELOG.md`, tags the merge commit, and publishes a release whose notes are
  that version's changelog section (via `.github/scripts/changelog-section.sh`),
  replacing the manual copy-the-changelog-into-a-new-release step. It is
  idempotent and runs only when `CHANGELOG.md` changes.

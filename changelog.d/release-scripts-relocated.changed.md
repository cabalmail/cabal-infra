- Moved the operator-run release scripts (`promote.sh`, `collate-changelog.sh`)
  from `.github/scripts/` to `scripts/`, alongside the other locally-run tools.
  `.github/scripts/` is now reserved for scripts a workflow actually executes;
  the release scripts are run by a human and only trigger CI via the resulting
  push. `make promote` / `make changelog` are unchanged.

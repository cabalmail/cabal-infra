- **Pipeline column on the triage dashboard.** The `os27` routing feature —
  a second, Studio-owned tester/fixer pipeline toggled per issue by the
  `os27` label — is retired now that the Studio no longer runs a scheduled
  tester/fixer pair. The column, its per-row toggle, the `/api/route`
  endpoint, and the `--route-label` flag are gone from
  `scripts/triage-dashboard.py`.

- **Stale gate status in the scanner baseline record.**
  `terraform/infra/BASELINE.md` still said the IaC gate was "soft-fail
  until Phase 3" long after Phase 3 shipped - the workflow jobs it
  describes are commented `GATING (Phase 3)` and genuinely block the
  apply. It now states the real posture, names the mechanism (scanner
  jobs in `approval`'s `needs:` and `if:`, `apply` behind `approval`,
  plus the baseline-drift step), and records that the decay backlog is
  complete, so the header matches the now-empty decay table.

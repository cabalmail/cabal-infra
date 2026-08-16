- **Stage-only promotion to prod.** The direct-to-prod scaffolding
  carve-out is retired: every change now reaches `main` by promoting
  `stage` through the release flow (`make promote`), with no
  feature-branch -> `main` PRs. Planning docs that relied on the
  carve-out carry dated errata.

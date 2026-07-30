- **Pipeline routing in the triage dashboard.** Each row now shows which
  tester/fixer pipeline owns the issue — baseline or `os27` (the 27.x-beta
  pair) — as a fixed-footprint pill that toggles the `os27` label on GitHub,
  plus a stat tile that filters to routed issues. `--route-label` renames the
  label; an empty value hides the column.

- **Tester/fixer triage dashboard.** `scripts/triage-dashboard.py` serves a
  local table (port 5058, alongside the Apple release dashboard on 5057) of
  the open issues in the tester/fixer cycle: one fixed column per lifecycle
  label (`tester-found` / `accepted` / `fix-in-review` / `needs-retest`),
  related PRs with open/merged/closed state discovered via cross-reference
  events, and new-tab links to each issue and PR. Closed and non-cycle
  issues are omitted. Data comes live from the GitHub GraphQL API through
  `gh` (or a `GITHUB_TOKEN`), with the same refresh/auto-refresh/theme
  chrome as the Apple dashboard.

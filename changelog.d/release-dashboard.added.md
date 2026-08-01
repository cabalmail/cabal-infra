- **Release dashboard.** `scripts/release-dashboard.py` (port 5059, same
  chrome as the Apple and triage dashboards) drives the stage→prod release
  cycle from one page: pending changelog fragments with patch/minor/major
  Promote buttons (runs `promote.sh` with all its guards in a private clone
  pinned to stage), the stage→main PR's checks with a Merge button that arms
  when they pass, every workflow run waiting on an environment approval gate
  — fully paginated, so a run can never hide below the fold of the Actions
  tab — with per-run Approve buttons, the deploy runs the merge actually
  triggered tracked through to the published GitHub release, and a table of
  recent releases. `promote.sh` gains `--no-watch` for callers that monitor
  PR checks themselves.

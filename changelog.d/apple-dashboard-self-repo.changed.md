- **Self-pointing `--repo` for the Apple release dashboards.**
  `apple-dashboard-app.py` and `apple-release-dashboard.py` now default
  `--repo` to the checkout containing the script (matching the triage
  dashboard) instead of the current directory, so they work from any
  working directory without flags.

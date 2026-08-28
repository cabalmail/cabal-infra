- **Dashboards refresh when their tab regains focus.** The release, triage,
  and Apple release dashboards re-fetch their data when the browser tab
  becomes visible or the window regains focus, so a dashboard left open in
  the background is current the moment you switch back to it. Focus-driven
  refreshes are throttled to one per 15 seconds so rapid window-switching
  doesn't hammer GitHub or App Store Connect.

- **Triage dashboard finds PRs on locked issues.** The PR column relied on
  GitHub cross-reference events, and GitHub records none on a locked
  conversation - so once bot-opened issues began locking at creation
  (`lock-bot-issues.yml`, 2026-08-16) every fixer PR vanished from the board
  (e.g. #1129 showed no PR although #1135 addressed it). The dashboard now
  also scans the repo's PRs for a closing reference, a `#N` mention in the
  body, or a `fixer/N-...` head branch, and unions that with the timeline.

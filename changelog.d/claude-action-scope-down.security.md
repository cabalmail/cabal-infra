- The Claude automation workflow no longer runs with
  `--permission-mode bypassPermissions`. Both jobs now use `acceptEdits`
  plus an explicit `--allowed-tools` allowlist that omits destructive
  shell verbs, and the untrusted issue/PR text embedded in the prompt is
  fenced inside an `<untrusted-issue>` CDATA delimiter with an
  instruction to treat it as data. The Dependabot remediation prompt
  gets the same fencing. The allowlist-maintenance procedure is
  documented in `docs/github.md`.

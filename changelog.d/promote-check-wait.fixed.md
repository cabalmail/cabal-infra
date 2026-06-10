- `make promote` no longer reports "some checks did not pass" right after
  opening the PR. `gh pr checks` returns immediately when a just-created PR has
  no checks registered yet (the same replication lag that delays the PR
  appearing in the web UI), which `promote.sh` misread as a failure. It now
  waits for checks to register before watching them and reports the real outcome
  from `gh`'s exit code (passed / failed / still pending / none registered).

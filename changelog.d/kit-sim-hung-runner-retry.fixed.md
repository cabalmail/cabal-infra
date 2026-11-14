- **Kit simulator test jobs failing before any test ran.** `apple.yml`'s
  "Test CabalmailKit (iOS)" job now and then failed about 13 minutes in with
  "The test runner hung before establishing connection", having run
  nothing, which turned `apple-gate` red and, on a `stage` or `main` push,
  skipped the TestFlight uploads (#2436). xcodebuild boots a new simulator
  only when testing starts, and that first boot keeps the three-core runner
  saturated for minutes, so the suite's bare `xctest` runner was sometimes
  refused by the device's service hub three times running. The Kit
  simulator legs now run their test command once more when exactly that
  happened. `runner-hung-before-tests.py` accepts only that error with no
  test started, so a run that produced a result is never repeated, and
  `xcodebuild-test.sh` never tries a third time and leaves a warning
  annotation on a run that retried.

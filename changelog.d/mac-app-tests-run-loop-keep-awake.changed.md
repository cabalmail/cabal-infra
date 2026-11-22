- **Mac app-layer tests no longer wait 0.1 s on every async fixture.**
  XCTest waits for an async `setUp`, test or `tearDown` by running the main
  run loop in slices of up to 0.1 s that end early only when a run-loop
  source is handled, so in the idle host app each one cost a tenth of a
  second however quickly it finished. `CabalmailMacTests` now has a principal
  class, `TestRunLoopKeepAwake`, that signals a do-nothing source a thousand
  times a second. The suite's 3,080 tests ran in 140 s instead of 298 s on
  the same machine and build.

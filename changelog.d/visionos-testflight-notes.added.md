- **"What to Test" notes on visionOS TestFlight builds.** A prod release
  set the TestFlight notes on its iOS and macOS builds only: the visionOS
  build shares the iOS app record and could share its build number, and
  the notes script had no way to tell the two builds apart. Since the
  build lookup now matches the platform (#2518), `testflight-assign` sets
  the notes on every platform's build, visionOS included.

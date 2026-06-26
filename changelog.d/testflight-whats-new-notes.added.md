- Prod TestFlight uploads now publish "What to Test" notes automatically. After
  the iOS and macOS builds upload, the Apple workflow waits for App Store Connect
  to finish processing the build and sets its beta release notes from the top
  section of `CHANGELOG.md`, so testers see what changed in each release. Stage
  uploads are unaffected.

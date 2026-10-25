- **Fewer macOS runners per Apple CI run.** `lint.yml`'s macOS `swift`
  job repeated the SwiftLint and platform-conditionals steps that
  `apple.yml`'s `kit-test` macOS leg runs on every Apple PR; it is now an
  Ubuntu `platform-conditionals` job, and SwiftLint runs only in
  `apple.yml`. The unsigned `app-build` legs no longer run on `main` and
  `stage` pushes, whose `upload-ios` and `upload-mac` archives build the
  same apps for the same device SDKs in Release; `approval` no longer
  waits on them, and `apple-gate` accepts their skip on those runs. An
  Apple PR now holds six macOS runners instead of seven, and a stage or
  main push eight instead of twelve.

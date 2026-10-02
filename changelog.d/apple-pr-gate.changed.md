- **Apple builds and tests run on every pull request.** `apple.yml` now
  triggers on PRs touching `apple/**`: CabalmailKit tests on macOS and the
  iOS simulator, both app-layer suites (which compile the iOS and Mac
  apps), and unsigned visionOS and watchOS builds, summed up in one
  `apple-gate` check. Previously a PR got only SwiftLint, and every build
  and test ran after merge. A PR run never reaches the approval gate or
  the uploads, and a newer push to the PR cancels its stale run. The
  iOS-hosted app-layer suite now also gates the TestFlight upload, and
  `lint.yml`'s SwiftLint job moves to the same `xcode-27` image as
  `apple.yml`.

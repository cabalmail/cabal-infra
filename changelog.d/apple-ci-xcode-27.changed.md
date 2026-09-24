- Apple: **Built with Xcode 27 and the 27.0 SDKs.** CI moved every
  macOS job, including the TestFlight archives, from GitHub's `macos-26`
  image (Xcode 26.6) to `xcode-27` (Xcode 27.0 GA on a macOS 27 host),
  so the shipped apps now link against the 27.0 SDKs and pick up the
  SDK-gated behaviours of iOS 27, macOS 27, and visionOS 27. The
  advisory Xcode 27 forward-compatibility jobs, redundant once the real
  legs run there, were removed. Tests run on the 27.x simulator runtimes
  only; older runtimes are no longer exercised in CI.

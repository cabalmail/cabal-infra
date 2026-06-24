- Added `make apple` targets that wrap `scripts/build-apple.sh`, so a local
  Apple build/lint check is as discoverable as `make scan`. `make apple` runs
  the full generate + lint + build sweep; `apple-lint`, `apple-macos`,
  `apple-ios`, `apple-visionos`, and `apple-kit-test` select a single step.
  macOS with full Xcode only.

- **Native visionOS build in CI.** `apple.yml` now compiles the Cabalmail
  scheme for visionOS in the unsigned build gate (catching xros-only compile
  breaks that an iOS build misses) and ships a native visionOS archive to
  TestFlight alongside the iOS one, so the Vision Pro can install the real
  app — layered parallax icon and all — instead of the iPad build in
  compatibility mode.

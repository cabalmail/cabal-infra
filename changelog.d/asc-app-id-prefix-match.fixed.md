- **TestFlight attach no longer stalls 40 minutes on the iOS and visionOS
  legs.** App Store Connect prefix-matches its bundle-id filter, so the
  upload job's app lookup for `com.cabalmail.Cabalmail` sometimes resolved
  the macOS app record instead, polled that app for a build it would never
  hold, and ended green with a "never surfaced" warning while the build sat
  unattached. The lookup now matches the bundle id exactly; the notes step
  shares the fix.

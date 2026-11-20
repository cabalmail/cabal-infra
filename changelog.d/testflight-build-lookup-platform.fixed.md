- **TestFlight build lookup matches the platform.** The iOS and visionOS
  builds share an App Store Connect app record, and each upload leg
  stamps its build number from the clock, so the two legs can stamp the
  same number. `assign-testflight-group.py` and `set-testflight-notes.py`
  looked a build up by number alone and took whichever platform's build
  App Store Connect listed first, which could attach one build to its
  TestFlight group twice and leave the other outside every group with
  every job green. Both now also match the build's platform, which
  `apple.yml` and `extensions.yml` pass as `ASC_PLATFORM` (#2518).

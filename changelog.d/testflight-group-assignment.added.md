- **Deterministic TestFlight distribution.** The Apple upload jobs now
  attach every uploaded build to the internal test group matching its
  branch (`stage` pushes → the `stage` group, `main` → `prod`) via the
  App Store Connect API, instead of relying on App Store Connect's
  fire-once automatic distribution, and fail the job when a build cannot
  be attached. Requires internal groups named `stage` and `prod` on each
  app record, with automatic distribution switched off.

- **TestFlight uploads of the Safari extension host.** The host app never
  declared its export-compliance status, so every upload landed in App Store
  Connect as "Missing Compliance" — a state in which the build is not
  internally testable, which made the automatic TestFlight group assignment
  fail outright rather than merely awaiting paperwork.

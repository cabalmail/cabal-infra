- **Faster Apple dashboard refresh.** The App Store Connect queries now run
  concurrently (both apps in parallel, and each app's groups and builds
  queries overlapped), the immutable app-record lookup is cached for the
  process lifetime, and the server app overlaps the repo side (git fetch,
  changelog parsing, log walks) with the ASC side. Pending-fragment authored
  dates are memoized like feature landings, and a dead per-fragment
  first-parent log walk was dropped. Each refresh logs its timing to stderr.

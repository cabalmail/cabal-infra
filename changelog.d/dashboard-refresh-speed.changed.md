- **Faster Apple dashboard refresh.** The App Store Connect queries now run
  concurrently (both apps in parallel, and each app's groups and builds
  queries overlapped), the immutable app-record lookup is cached for the
  process lifetime, and the server app overlaps the repo side (git fetch,
  changelog parsing, log walks) with the ASC side. The build ledger is
  cached incrementally (in memory and on disk, default
  `~/.cache/cabalmail-apple-dashboard`, `--no-asc-cache` to disable): a
  refresh refetches only pages young enough to still change and serves
  settled history from the cache, deriving expiry locally from
  `expirationDate`, so steady-state refreshes fetch about one page per app
  instead of the full history. The volatile window is 14 days, sized so each
  app's refetch stays inside one page at the current upload rate; the
  beta-detail recovery chunks run concurrently; and the server shares one
  in-flight refresh among concurrent requests instead of running a full
  App Store Connect round per caller. Group assignments made through the
  dashboard mark the build dirty so it is refetched. Pending-fragment
  authored dates are memoized like feature landings, a dead per-fragment
  first-parent log walk was dropped, and each refresh logs per-phase timing
  to stderr.

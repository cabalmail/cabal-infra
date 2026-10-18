- **Concurrency-warning sweep of the macOS app-layer test bundle, now
  warning-free and held there.** The 39 warnings that needed no judgement are
  gone — discarded `MailMutationService` outcomes, three never-mutated
  `weak var`s, two unnecessary `await`s and an unused binding — and so are
  the 178 actor-isolation ones: a `@MainActor` test class's `setUp`/`tearDown`
  now overrides the `async throws` hooks, which can carry the class's
  isolation where the synchronous ones cannot, and three classes that measure
  main-actor view code gained the annotation. The last 31, all `sending value
  of non-Sendable type`, were one shape — a poll closure handed to a
  nonisolated helper from a main-actor test — and now poll on the main actor
  instead. With the count at zero the bundle builds with
  `SWIFT_TREAT_WARNINGS_AS_ERRORS`, which replaces the three per-group
  promotions and guards the ungrouped isolation diagnostics those could not:
  a warning-emitting test now fails the build rather than growing a backlog
  nothing failed on.

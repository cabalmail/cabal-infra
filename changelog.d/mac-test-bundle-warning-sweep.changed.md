- **Concurrency-warning sweep of the macOS app-layer test bundle.** The 39
  warnings that needed no judgement are gone — discarded
  `MailMutationService` outcomes, three never-mutated `weak var`s, two
  unnecessary `await`s and an unused binding — and so are the 178
  actor-isolation ones: a `@MainActor` test class's `setUp`/`tearDown` now
  overrides the `async throws` hooks, which can carry the class's isolation
  where the synchronous ones cannot, and three classes that measure
  main-actor view code gained the annotation. The bundle is down from 246
  warnings to 31, all of them `sending value of non-Sendable type`. The
  three diagnostic groups it is clean of (`NoUsage`, `WeakMutability`,
  `UnnecessaryEffectMarker`) are errors on that target so they cannot come
  back; the isolation diagnostics are ungrouped, and blanket
  warnings-as-errors is what will guard them once the `sending` sites go.

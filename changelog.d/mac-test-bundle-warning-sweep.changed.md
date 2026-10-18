- **Mechanical concurrency-warning sweep of the macOS app-layer test bundle.**
  The 39 warnings that needed no judgement are gone — discarded
  `MailMutationService` outcomes, three never-mutated `weak var`s, two
  unnecessary `await`s and an unused binding — taking the bundle from 246
  warnings to 207. The three diagnostic groups it is now clean of
  (`NoUsage`, `WeakMutability`, `UnnecessaryEffectMarker`) are errors on
  that target, so they cannot come back while the remaining actor-isolation
  and `sending` warnings are worked through.

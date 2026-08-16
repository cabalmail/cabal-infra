- **Lifecycle flow-chart on the triage dashboard.** An SVG diagram below the
  issue table maps every lifecycle label and the routes between them — entry
  via `needs-verification` or `tester-found`, the verify pass's verdicts,
  triage, the `accepted`/`fix-in-review`/`needs-retest` chain, and each
  terminal state — in the same label colors as the table, themed for light
  and dark. The Accept button is now also disabled while an issue still
  awaits verification, since accepting an unverified report wedges the
  tester's verify pass (its verdict transitions are all forbidden on an
  accepted issue).

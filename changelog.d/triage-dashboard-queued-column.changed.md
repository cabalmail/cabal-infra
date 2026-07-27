- **Triage dashboard: `accepted` and `needs-retest` share one column.** The
  fixer's reconcile step swaps one label for the other when a fix goes live,
  so the two are mutually exclusive; they now render as a single "queued"
  column whose pill names the active label, the same grouping the pre-triage
  labels use. The Accept button is disabled while either label is present
  (previously only `accepted`), with `--accept-block-labels` to repoint the
  extra blockers.

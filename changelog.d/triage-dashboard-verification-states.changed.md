- **Triage dashboard covers the verification flow.** Issues filed by the human
  or a coding agent enter the tester/fixer cycle via a `needs-verification`
  label, which the daily tester resolves to `verified` or `verify-blocked`;
  the dashboard previously keyed only on `tester-found` and missed them.
  Columns now represent pipeline states rather than single labels: the four
  pre-triage labels share one "triage" column whose pill (verifying / found /
  verified / blocked) shows where verification stands, and `--stages` accepts
  `name=label|label` groupings.

- **Release dashboard holds Promote while merged fixes await tester
  sign-off.** When an open tester/fixer-cycle issue has a claimed fix
  (a `fixer/N-…` branch, a closing reference, or an "Addresses #N"-style
  mention) merged on stage but not yet released, the Promote buttons are
  disabled and a banner lists the pending issues with their PRs — closing
  the issue, which the retest pass does, releases the hold. Bare `#N`
  context mentions deliberately don't count, and released-vs-pending is
  decided per merge commit against main, so an already-shipped fix never
  re-blocks.

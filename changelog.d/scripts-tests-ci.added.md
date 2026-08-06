- **CI gate for `scripts/tests`.** A new `scripts-tests.yml` workflow runs
  the `scripts/tests` unittest suites on pull requests that touch
  `scripts/**` and on pushes to the named branches; previously the suites
  ran only by hand.

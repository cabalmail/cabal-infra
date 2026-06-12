- Pushes to `stage` and `development` now path-filter against the
  commits actually pushed instead of the branch's full divergence from
  `main`. `paths-filter`'s `base` defaults to the repository default
  branch, so a push to a non-default deploy branch re-deployed every
  area (and every docker tier) in which the branch differed from
  `main` - e.g. a docker-only push also redeploying the React bundle.
  Pushes to `main` were unaffected.

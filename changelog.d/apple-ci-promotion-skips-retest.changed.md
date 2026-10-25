- **A main push no longer re-runs the Apple tests the release PR passed.**
  main receives only stage promotions, whose tree is the stage tip's, and
  the release PR's `apple.yml` run tests that tree first. A new
  `promotion-verdict` job (`.github/scripts/apple-promotion-verdict.py`)
  checks that the push is such a merge and that the run on the stage tip
  passed every test leg; when it did, `kit-test`, `app-test` and
  `ios-app-test` skip and the run goes straight to the `gate-prod`
  approval and the uploads, which still archive every app. Anything it
  cannot show, an API error included, runs the full suite. A PR into main
  now keeps `kit-test`'s visionOS leg so its run covers every leg the main
  push would, and the upload jobs pin themselves to `approval`'s result so
  the skips above them don't skip them too. A promotion's main push now
  holds three macOS runners instead of eight, and its approval no longer
  waits on a test pass that took 6 to 9 minutes plus runner queueing.

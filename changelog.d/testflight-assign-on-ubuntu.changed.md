- **TestFlight group assignment off the macOS runners.** After `altool`
  finished, each of `apple.yml`'s iOS, visionOS and macOS upload legs
  went on polling App Store Connect from its macOS runner until Apple had
  ingested the build and it could join the branch's TestFlight group: 1.5
  to 5 minutes a leg on recent pushes, with a 40-minute ceiling. The legs
  now hand their build numbers to a new `testflight-assign` job, which
  attaches each build and, on `main`, sets its "What to Test" notes from
  an Ubuntu runner, so a macOS runner is released as soon as its upload
  is done. A Mac build is now attached even when the optional Developer
  ID notarization after its upload fails.

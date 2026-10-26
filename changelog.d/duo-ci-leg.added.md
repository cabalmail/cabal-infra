- **An advisory iPhone Duo leg in the Apple CI.** `apple.yml`'s new
  `ios-duo-test` job runs the iOS-hosted app-layer suite on an iPhone Duo
  simulator, the one leg that executes code behind
  `#available(iOS 27.1, *)`: every other iOS leg runs on the iOS 27.0
  runtime. The runner image's iOS 27.1 runtime supports only the Duo, so
  `resolve-sim-destination.sh` finds it by the "iPhone Duo" prefix with no
  download. It runs on stage pushes, manual runs and PRs whose branch name
  contains `duo`, with `continue-on-error` and outside `apple-gate` and
  `approval`, so a red leg blocks no merge and no upload. It cannot fold:
  no command changes the simulator's posture.

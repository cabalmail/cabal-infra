- **The iPhone Duo CI leg is required where it runs.** `ios-duo-test`,
  the one Apple leg that runs the iOS 27.1 code on a Duo simulator, now
  fails `apple-gate` and holds the stage uploads when it goes red, after
  46 green runs as an advisory leg. It still runs only on stage pushes,
  manual runs and PRs whose branch name contains `duo`, and its skip
  elsewhere counts as a pass.

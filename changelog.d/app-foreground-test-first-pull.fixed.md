- **A flaky Apple app-layer test of the settings pull at foreground.**
  `AppForegroundTests` waited for the settings sync's edit observer as
  the sign that the session's first pull had gone. Since the sync started
  attaching the observer before that pull, the pull could land inside
  `testReturningToTheForegroundReconcilesThePreferencesOnce` and be
  counted as the foreground's, which failed a stage run of the Mac
  app-layer suite. The setup now waits for the pull's request itself.
  Test only.

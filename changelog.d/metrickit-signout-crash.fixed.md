- Fixed a crash in the Apple clients when signing out with crash reporting
  enabled. The MetricKit collector was owned by the per-session client and
  unsubscribed from `MXMetricManager` in `deinit`; because that unsubscribe
  is dispatched asynchronously, it ran after the collector had been freed,
  faulting on the next user interaction. The collector is now a
  process-lifetime singleton, so the subscriber outlives sign-out.

- **TestFlight upload no longer fails on recovered network retries.** The
  iOS/macOS upload steps guarded against altool's unreliable exit code by
  failing on any `ERROR:` log line, which false-failed a successful upload
  when a transient "connection was lost" chunk error was retried and the
  final banner read `UPLOAD SUCCEEDED`. The guard now trusts altool's final
  verdict: pass only on `UPLOAD SUCCEEDED` with no failure banner, warn on
  recovered retries, and still fail on `UPLOAD FAILED`, `STATE_ERROR`, or a
  missing verdict.

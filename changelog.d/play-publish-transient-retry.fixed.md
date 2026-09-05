- **A transient Play Console refusal no longer loses an Android stage
  build.** A single 503 from Google failed the upload job after the bundle
  had already been built and signed, and since the artifact lives only
  inside that job, the commit produced no internal-track build at all. The
  publish now retries a transient refusal a few times with backoff — but
  only when the run's own output shows the Play edit was never committed,
  since re-running a publish that committed would publish the bundle twice.

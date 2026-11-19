- **A prod Android upload no longer loses to a stage upload that started
  after it.** Stage and main publish to one Play track, and each run took its
  version code, the workflow's run number, when it started. A main run then
  waits for the `gate-prod` approval, so a stage run started meanwhile
  published a higher code first and Play refused the lower one ("does not
  allow any existing users to upgrade"), which is how the 1.54.0 prod build
  failed to publish (#2491). The publisher now runs with
  `ResolutionStrategy.AUTO`: while it builds the bundle it asks Play for the
  highest code on any track and uses that plus one when the run number is not
  above it. A re-run of a failed upload is publishable for the same reason.
  The version code that ships can therefore be above the run number, so the
  upload job's summary now names the code that was published, read from the
  publisher's own output by `publish-play-bundle.py`.

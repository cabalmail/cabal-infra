- **A stage Android upload can no longer knock out a prod one that is still
  building.** Play keeps one open "edit" per account, and the publisher opens
  its edit when it resolves the version code, minutes before it uploads the
  bundle. A stage upload that started in those minutes opened a second edit,
  Play invalidated the first, and the prod upload failed with "This Edit has
  been deleted", which is how the first 1.55.0 prod build failed to publish
  (#2505). `android.yml`'s upload job now holds a concurrency group shared by
  stage and main, so an upload waits for the one in progress instead of
  starting beside it; neither is cancelled for the other. A new scripts test
  reads the workflow and fails if the publishing job loses the group, if the
  group comes to vary with the ref, or if it is set to cancel an upload in
  progress.

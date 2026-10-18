- **Changelog fragments for every change.** The changelog now records
  engineering history, not only user-facing release notes: every PR must add
  (or edit) a fragment unless it changes only documentation, enforced by the
  new `changelog-fragment` check. The `no-changelog` PR label no longer skips
  the fragment; it only waives the `Apple:`/`Android:` prefix, keeping a
  non-user-facing client entry out of the tester release notes.

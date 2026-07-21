- **React compose autosave writes real drafts.** The compose overlay's
  autosave was a placeholder that debounced a local timestamp instead of
  calling the server, so the "Saved just now" label appeared while nothing
  was actually saved and closing the overlay silently dropped the draft
  (issue #718). The autosave now calls `/save_draft`, tracks the returned
  UIDPLUS coordinates as `replaces_*` on subsequent saves, and always
  flushes a final save on close-without-send. `/send` passes the current
  draft coordinates as `discard_draft_*` so the stale copy is expunged
  after delivery. The label stays as "Draft not saved" until a real
  round-trip succeeds. Attachments are still uploaded and included only on
  Send in this pass; draft copies omit them to avoid re-uploading blobs on
  every debounce.

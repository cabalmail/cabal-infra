- Apple: **A sign-out wipe that fails now says so.** Every step of the
  wipe that clears an account's local data at sign-out (saved message
  lists and bodies, drafts, the outbox, feeds, the saved address and
  folder lists) discarded its error, and the two mail caches hid a failed
  removal even from the wipe, so a wipe that left the last account's mail
  on the device looked the same as one that worked. Each step that fails
  now writes an error line to the unified log and to Settings > Debug
  Log, naming what was not cleared. The wipe is still best-effort: one
  failed step does not stop the rest, and nothing retries here.

- Apple clients: an action taken on a message (mark read/unread, flag,
  archive, move) just before the folder's background refresh no longer
  appears to undo itself. A refresh dispatched before the change reached
  the server returned the row's pre-change state and the merge applied it
  verbatim, reverting the optimistic update until the next refresh. The
  message list now shields in-flight local writes: an optimistically
  removed row stays gone and a freshly toggled flag stays toggled (in
  memory and in the on-disk snapshot) until that write resolves, after
  which the following refresh carries server truth.

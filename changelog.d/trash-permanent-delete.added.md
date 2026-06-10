- Deleting a message that is already in Trash now deletes it forever
  (after a confirmation), in both the React and Apple clients, and the
  Trash folder offers an "Empty trash" action (inline button in React,
  context menu on Apple) that permanently deletes its entire contents.
  Backed by two new Lambda endpoints, `/purge_messages` and
  `/empty_trash`, which flag-and-expunge server-side, refuse to operate
  on non-trash folders, and clear the affected messages from the S3
  body cache.

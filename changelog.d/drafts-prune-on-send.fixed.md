- Apple: **Sending a draft clears it from the Drafts list right away.** The row stayed
  on screen for a minute or more after the send completed, even though the server copy
  was already gone, because nothing invalidated the folder the app had just acted on.
  The compose surface now prunes the row the moment the send lands, the same way the
  reader's archive and move actions do.

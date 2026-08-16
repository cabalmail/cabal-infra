- Apple: **Phantom Drafts row after sending an autosaved draft.** A draft left
  open past the 60-second server autosave was saved back under a new UID, and
  sending it only retired that newest copy — so the Drafts list kept showing a
  row for the copy the autosave had already replaced. The row opened a fully
  populated reader with Edit Draft, from which the message could be sent a
  second time. Sending now retires every Drafts copy the compose session
  created.

- Apple: **Bulk actions on search results no longer hit a second
  message.** Message IDs are only unique within a folder, so a search
  across folders could show two results with the same ID, and selecting
  one selected both. Marking read, flagging, moving, or archiving that
  selection acted on both messages, and marking read or flagging could
  crash the app. Those messages are now left unchanged with a note
  saying why, and the rest of the selection is acted on as before; open
  each one to act on it.

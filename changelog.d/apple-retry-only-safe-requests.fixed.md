- Apple: **No "already exists" after a dropped connection.** When the
  connection drops mid-request, the app now sends a second copy only of a
  request that is safe to repeat. Creating or deleting a folder, revoking
  an address, saving mail rules, adding or removing a feed or feed folder
  and importing OPML are sent once, so a change that went through no
  longer comes back as "already exists" or "changed on another device";
  the dropped connection reads as a network error instead. Emptying the
  Trash is sent once too, so a late second copy can't delete mail that
  reached the Trash after you confirmed. Archiving, moving, flagging,
  sending and signing in keep their quiet retry.

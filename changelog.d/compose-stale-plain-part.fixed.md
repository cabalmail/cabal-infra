- Apple: **Editing in the Rich Text pane no longer sends a stale plain-text
  part.** A composer that opens with a body already in it — a resumed draft,
  a reply, or any message at all once a signature preference is set — used to
  ship that untouched seed as the message's `text/plain` part while the
  `text/html` part carried what was actually typed. A plain-text recipient
  read text the sender never wrote, and reopening the draft (which prefers
  the plain part) brought back the pre-edit body, so the edit looked lost.
  The two parts now agree: the pane the user actually wrote in wins.

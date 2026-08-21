- Apple: **A send that races the draft autosave no longer leaves a copy in
  Drafts.** Tapping Send while the 60-second server autosave was mid-round
  trip delivered the message and kept a full, re-sendable copy of it in
  `Drafts` for good. `/send` carries the draft cleanup, so a send ends the
  session's server copy exactly as Discard does — it now runs through the
  same mutation queue, waiting behind any save in flight and refusing every
  tick that follows. A send that *fails* leaves the composer up and the
  session open, so the close-without-send push still reaches the server.

- Apple: **Readable HTML bodies in "Original" mode.** The reader now injects a
  `width=device-width` viewport meta on both render paths, not just in Reader
  mode. Without it WebKit laid messages out at its 980pt desktop viewport and
  scaled the result down to the pane — about 40% on a phone — so any message
  that ships no viewport of its own was legible only by pinch-zoom. A sender's
  own viewport still wins, and the injection never displaces a `<!DOCTYPE>`, so
  author CSS renders exactly as before.

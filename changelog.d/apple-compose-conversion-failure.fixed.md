- Apple: **A message the editor fails to convert stays unsent.** Send
  refused only when the editor had stopped working altogether. If a single
  conversion failed while it was still running, the message went out
  anyway: without its HTML part from the Markdown pane, without its
  plain-text part from the rich pane, or, when reading the rich pane
  failed, carrying the quoted original or signature instead of what was
  typed. Send now stops and says nothing was sent, with the message still
  in the window to try again. Autosave skips that round, and closing the
  window keeps the last saved draft instead of saving an empty one over it.

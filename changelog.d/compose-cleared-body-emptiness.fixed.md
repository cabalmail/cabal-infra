- Apple: **Clearing the body now clears the draft.** Typing in the composer's
  Rich Text pane and then deleting it all left the composer dirty for the rest
  of the session: Cancel still raised "Discard draft?" over a visibly empty
  message, autosave still wrote one to the server, and sending it carried
  WebKit's leftover block markup as the body. The composer now asks whether
  the pane holds anything *now* rather than whether it was ever touched, and
  an emptied pane is treated as empty. A reply's quoted original and a resumed
  draft's body are still content, as they were.

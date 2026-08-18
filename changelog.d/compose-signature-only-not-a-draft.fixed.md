- Apple: **A signature on its own no longer counts as a draft.** With a
  signature configured in Settings, every new message the composer opened
  arrived with the signature already in the body — so abandoning one raised
  the "Discard draft?" dialog on macOS and iPad, and leaving one open long
  enough saved a draft to the server containing nothing but the signature.
  The composer now asks whether the *user* wrote anything rather than whether
  the body is empty, and it asks about the body as it stands: typing in the
  Rich Text pane and then deleting it all used to leave the composer dirty
  for the rest of the session. A reply's quoted original and a resumed
  draft's body are still content, as they were. Emptying the rich pane also
  no longer leaks WebKit's leftover block markup into the sent message.

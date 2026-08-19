- Apple: **Discard Draft no longer leaves the draft on the server.** Pressing
  Discard while the 60-second background save was mid-round-trip expunged the
  copy the composer was holding and then let the completing save append a
  fresh one, so a draft the user had explicitly thrown away stayed in Drafts —
  and Edit Draft on it reopened the message with Send live. Discarding now
  waits for any save already in flight and drops the copy that save landed,
  and a save that arrives after a discard is refused outright.

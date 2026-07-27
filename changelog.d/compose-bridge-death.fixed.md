- Apple: **Compose no longer hangs or sends an empty body when the rich-text
  editor dies.** The WebKit bridge that assembles the message body now reports
  its own death — a `ready` handshake that never arrives, a failed boot script,
  or a web content process that stops after boot — instead of leaving Send
  spinning forever or converting the message to an empty string. Send refuses
  with an explanatory banner, and draft pushes to the server are skipped rather
  than replacing a good copy with an empty one.

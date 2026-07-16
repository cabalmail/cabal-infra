- Apple: **mailto: links populate the compose fields again (macOS).**
  The stray-window fix rerouted incoming `mailto:` clicks to the compose
  window scene, which spawned its window with a blank draft and dropped
  the URL — To, Cc, Bcc, Subject, and body arrived empty. The compose
  window now seeds itself from the delivered URL, and a `mailto:` click
  that cold-launches the app restores the signed-in session instead of
  showing a sign-in placeholder.

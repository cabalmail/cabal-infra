- Apple: **No stray main window when opening a mailto: link (macOS).**
  Clicking a `mailto:` link with Cabalmail set as the default mail reader
  opened the compose window as intended but also spawned an empty second
  main window; the main window group no longer creates a new window in
  response to external URL events, so only the compose window appears.

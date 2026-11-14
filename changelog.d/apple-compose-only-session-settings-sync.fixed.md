- Apple: **No settings sync when the app starts in a compose window.** A
  compose window that the system restored at launch, or opened for a
  `mailto:` link, restored the session without the app's settings, so
  for as long as that process ran nothing was pulled from or pushed to
  the server, even after a main window opened, and a flag added in
  Settings could be dropped from a feed item it was put on. The compose
  window now hands the settings to the session as the main window does,
  and a session that was started without them begins syncing when they
  arrive (#2441).

- Apple: **Messages deleted elsewhere while a folder was closed leave the
  offline list.** The message list saves the folder position its rows were
  proven to sit at beside the rows themselves, so the first refresh after a
  launch can prove a row removed elsewhere gone by re-reading its own window
  rather than the whole folder. In any folder deeper than one read, such a
  row used to stay on the device for good: it was gone from the list online,
  but an offline launch still showed it and a Spotlight hit still opened a
  message the server no longer had. The saved position is refused — leaving
  the previous behaviour — unless it still names exactly the rows on disk and
  the order they were read in, and it goes with them at sign-out.

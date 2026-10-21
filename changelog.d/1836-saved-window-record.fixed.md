- Apple: **Messages deleted elsewhere while a folder was closed leave the
  offline list.** The message list saves the folder position its rows were
  proven to sit at beside the rows themselves, so the first refresh after a
  launch can prove a row removed elsewhere gone by re-reading its own window
  rather than the whole folder. In any folder deeper than one read, such a
  row used to stay on the device for good: it was gone from the list online,
  but an offline launch still showed it and a Spotlight hit still opened a
  message the server no longer had. The saved position vouches for its own
  rows and no others, so it survives sitting beside the deeper pages the
  offline cache keeps — a folder scrolled past its first page used to
  discard it on the next write, which left the launch after that with
  nothing to re-read against. It is refused, leaving the previous
  behaviour, if a row it names has left the device or it was read in
  another order, and it goes with the rows at sign-out.

- Apple: **One device's older settings replacing the account's.** Every
  settings change sent the device's whole set of synced settings, so a
  device that had not yet seen a change made on another one put its
  older copy back: a renamed flag, the signature, a folder's remembered
  filter. On a device new to the account whose first sync had failed,
  the first change (a tap on a folder's Unread pill was enough) emptied
  the account's signature and Default From and reset nine more settings.
  A device now sends only the settings changed on it, sends nothing
  until it has read the account's, and tells the server which version of
  them it was working from; when another device has changed them since,
  it takes those changes in and sends again, and two edits of the flag
  list on two devices are merged (#2452, #2464). Also: a setting changed
  in the moment a session starts is no longer lost, a settings sync is
  no longer held while one change cannot be sent, and a second account
  signed in on the same device no longer sends keys the first one had
  set (#2441, #2451). Needs the server from this release's API change to
  check versions; against an older server the device still sends only
  its own changes. Devices on 1.53.0 or older keep the old behaviour
  until they update.

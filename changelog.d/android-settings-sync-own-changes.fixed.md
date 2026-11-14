- Android: **Older settings replacing the account's.** Every settings
  change sent the device's whole set of synced settings and the display
  name, so a device that had not seen a change made on another one put
  its older copy back, and a device new to the account whose first sync
  had failed emptied the account's display name, signature and Default
  From with its first change. A device now sends only the settings
  changed on it, sends nothing until it has read the account's, and
  tells the server which version of them it was working from; when
  another device has changed them since, it takes those changes in and
  sends again, and two edits of the flag list on two devices are merged
  (#2452, #2464). A change that could not be sent is kept and goes at
  the next change or launch, where it used to be dropped. And the
  settings on a device belong to one account: when another account signs
  in they start from that account's own, where the flag list, signature,
  Default From and folder filters of the last account used to stay and
  reach the new account's settings (#2471). Against a server that
  predates the version check the app still sends only its own changes.

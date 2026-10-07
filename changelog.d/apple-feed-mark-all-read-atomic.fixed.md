- Apple: **A feed's Mark All as Read can no longer half-apply.** If the
  device's feed store failed partway through, the feed could end up marked
  read on this device with nothing queued to tell the server, so it stayed
  read here and unread everywhere else. The mark and its queued push are
  now written together or not at all (#1939).

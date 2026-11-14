- **A Default From address over 100 characters refused with the device's
  whole settings map.** `set_preferences` held the Default From address
  to the display name's bound of 100 code points, though an account can
  hold a longer address and an app can pick it; every settings push from
  that device was then answered 400. The address has its own bound now,
  320 code points, the longest address SMTP's limits allow (#2451).

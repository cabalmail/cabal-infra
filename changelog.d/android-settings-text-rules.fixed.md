- Android: **Settings sync stopped by an emptied flag name.** Clearing a
  flag's name in Settings stored the empty name, and the server refuses
  a flag with no name together with everything else in the same request,
  which on Android is every synced setting and the display name. Nothing
  said so, and each later change was lost at the next launch. A signature
  over 2,000 characters or a display name over 100 did the same. The
  flag editor no longer writes an empty name (leaving it with the field
  cleared gives the flag back the name it opened with), names are cut to
  what the server counts rather than at 32 UTF-16 units, the signature
  and the display name are cut to the server's limits when they are
  saved, and a value an older build stored is mended when the app next
  reads it (#2453).

- Apple: **A damaged feed cache can no longer stop mail from starting.**
  The on-device feed database migrates each schema step in a transaction,
  so an interrupted upgrade no longer leaves it half-applied, and a cache
  that still cannot be opened (corrupt, half-migrated by an older build,
  or from a newer one) is deleted and rebuilt from the server. If even
  that fails, the app starts without feeds instead of failing sign-in.

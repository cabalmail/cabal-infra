- Apple: **Settings no longer leak across accounts on one device.** The
  locally cached preferences (default view, default From address,
  mark-as-read, remote content, signature, theme, and the rest) were
  stored device-wide, so signing in as a different user showed — and let
  you overwrite — the previous account's choices, including a default
  From address the new account doesn't own. Each account now has its own
  local settings scope, activated at sign-in before the server copy is
  pulled, and the old device-wide values are deleted on first sign-in
  after updating (settings re-sync from the server, or reset to defaults
  for accounts that never synced). The local cache is now plain
  `UserDefaults` on this device only — the iCloud key-value mirror is
  gone entirely, so nothing is read from or written to iCloud, even as a
  fallback; cross-device sync rides the Cabalmail account.

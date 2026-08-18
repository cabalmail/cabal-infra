- Android: **Address/folder management, synced settings.** Three new
  destinations behind the folder list's menu (Phase 6). **Addresses** lists
  the user's addresses favorites-first with a star toggle, swipe or
  long-press to revoke (behind a confirmation), pull-to-refresh, and a
  "request new" action that reuses the compose picker's creation sheet - a
  favorite sorts to the top of both this list and the From picker.
  **Manage folders** shows every folder with a subscription switch and
  message count, a "new folder" dialog with a parent picker, and delete for
  empty user folders. **Settings** covers Account (display name, sign out),
  Reading (mark as read, remote content, render mode, folder count display,
  default sort), Composing (default From address, signature), Actions
  (dispose to Archive or Trash), Appearance (theme, dynamic color, accent,
  density) and About. The shared subset - display name, theme, accent,
  density, and the per-client behaviours the Apple client already syncs -
  round-trips through `/get_preferences` / `/set_preferences` (server wins
  on launch; the server merges per key), so a change here shows up on the
  web and Apple clients and vice versa; dynamic color and the default sort
  stay on the device. Every consumer follows the setting live: theme and
  system bars, accent seed when dynamic color is off, row density, folder
  badges, default sort, dispose target and its labels, mark-read-on-open,
  remote content "always", default render mode, and the default From and
  signature seeded into new composes.

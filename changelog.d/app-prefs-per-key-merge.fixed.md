- **Per-key merge for the synced `app` preference map.** `set_preferences`
  replaced the Apple clients' `app` map wholesale on every save, so once a
  newer client version introduced an additional preference key, a settings
  edit from a device still running an older version would silently delete
  it for every device. The server now merges the map per key (`app.x`
  nested updates, seeding the map on first save), making concurrent and
  cross-version edits last-write-wins per key; keys unknown to the saving
  client survive. An empty `app` map is now a no-op instead of wiping the
  stored map.

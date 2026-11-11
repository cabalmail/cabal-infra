- **SQLite foundation for the Apple stores.** `SQLiteDatabase` moved from
  the feed code to the Kit's `Persistence/` folder and gained a write
  transaction (`BEGIN IMMEDIATE`, rolled back on a throw), a schema
  migration runner keyed on `user_version`, BLOB binds and a `user_version`
  read and write that throw instead of swallowing a failure. The feed
  store runs on them with its schema unchanged, and a SQLite failure now
  reaches its callers as `CabalmailError.storage`. Debug builds take
  `-CabalmailFailNextWrite <table>`, which fails the next write to that
  table once, so a failed write can be shown live.

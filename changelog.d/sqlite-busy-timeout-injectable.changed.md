- **Four CabalmailKit tests no longer wait out SQLite's two-second busy
  timeout.** Each holds a lock on a store's file and asserts that the
  store's write fails, and the write waited the whole timeout first: about
  2.2 s per test on the iOS and visionOS simulator legs of `apple.yml` and
  about 4 s on the macOS leg, where the timeout's short sleeps are
  stretched. `SQLiteDatabase`, `SQLiteSetAside` and `RssStore`'s internal
  initializer now take the timeout as a parameter that defaults to the
  same 2,000 ms, so nothing that ships waits any differently, and the four
  tests pass 5 ms. Their assertions are unchanged.

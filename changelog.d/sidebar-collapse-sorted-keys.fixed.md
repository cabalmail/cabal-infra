- **Flaky sidebar-collapse seed tests.** `SidebarCollapse.scene` encoded a
  window's collapsed set with a plain `JSONEncoder`, which writes keys in an
  order that can change from one encode to the next within a process, so
  `testAWindowHoldingAnotherAccountsSetIsSeededAfresh` and
  `testAWindowWithNothingStoredSeedsOnMount` now and then compared two
  strings holding the same set and failed. The encoder now sorts keys, as
  the type already promised for the set itself, and a new test encodes one
  set across threads and pins the single sorted string it must produce.

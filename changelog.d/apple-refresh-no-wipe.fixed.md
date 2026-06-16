- The Apple message list no longer wipes a scrolled, deeply-paginated folder
  back to the top page on a routine background refresh. A flaky folder STATUS
  (missing or zero UIDVALIDITY) is no longer read as a mailbox rebuild, and an
  empty top-page fetch is no longer read as "every message was expunged" -- so
  the 60-second background refresh and the IDLE watcher reconcile new mail
  without discarding the loaded pages.

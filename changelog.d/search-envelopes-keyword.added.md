- **Search by custom flag.** `/search_envelopes` takes an optional
  `keyword`: one of the flag palette's keyword slots (`cabal-flag-01` ..
  `cabal-flag-20`), sent to IMAP as a `KEYWORD` criterion beside the
  other filters, in one folder or across all of them. Anything that is
  not a slot is a 400 before an IMAP session opens. The palette is not
  consulted, so the messages of a disabled or deleted flag can still be
  found. No client sends it yet, and a search without it is unchanged.
  Second server PR of cross-media Phase 2
  (`docs/1.x/cross-media-ux-plan.md`), for the per-flag filter on the
  mail list.

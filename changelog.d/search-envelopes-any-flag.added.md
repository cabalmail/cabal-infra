- **Search by any flag.** `/search_envelopes` takes an optional
  `any_flag`: only messages that carry the system flag or one of the flag
  palette's twenty keyword slots match. It goes to IMAP as one `OR` over
  `FLAGGED` and each slot's `KEYWORD`, beside the other filters, in one
  folder or across all of them. The palette is not consulted, so a
  message still carrying a deleted flag's slot is found, and a keyword
  the API never stores (`$Forwarded`, `NonJunk`) is not a flag. No client
  sends it yet, and a search without it is unchanged. Third server PR of
  cross-media Phase 2 (`docs/1.x/cross-media-ux-plan.md`), for the "Any
  flag" row of the per-flag filter on the mail list.

- **Search finds a word whatever capitalization it was written in.** The
  full-text index stored each word with its original casing while the search
  side also tried the query lowercased, so the two only ever met for words
  written all-lowercase or in Title case. A word in ALL CAPS (`OTP`, `AWS`, a
  shouty subject, a ticket prefix) was unreachable by any query casing, and a
  word with a capital inside it (`PayPal`) only by retyping it exactly — in
  subjects and bodies alike, and silently, as an empty result rather than an
  error. Terms are now folded to lowercase on the way into the index. Mail
  already indexed keeps the old terms until the index is rebuilt; the operator
  step is in `docs/operations.md`.

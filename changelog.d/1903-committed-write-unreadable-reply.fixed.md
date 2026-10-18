- Apple: **A rule save or Mark All as Read the server did keep.** Both
  endpoints commit before they answer, so a 200 whose body the client
  can't read is a write that landed — but a rule save reported a failure
  and left its version behind the server's, so the next save's 409 said
  the rules had been changed on another device, and Mark All as Read kept
  the folder's unread badge and rows although every message had been
  marked read. The rule editor re-reads the committed set instead, and the
  folder's after-effects run with only the flipped count lost.

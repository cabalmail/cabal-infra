- Apple: **Sign-out closes the feed store even when emptying it fails.** The
  ending session's store was closed only after its rows were dropped, so a
  database error at sign-out (a busy lock, a full disk, a damaged search
  index) left the file open: a feed refresh still running from that session
  could write the account's feeds back into the file the next account signs
  in on. The close now happens either way, and the error still reaches the
  caller.

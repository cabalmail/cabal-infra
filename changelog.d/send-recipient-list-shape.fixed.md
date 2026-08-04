- **A malformed recipient list is answered as a rejected request.** `/send`
  and `/save_draft` checked that `to_list`, `cc_list`, and `bcc_list` were
  present and free of header injection, but not that they were lists at all.
  A client sending one as a bare address string got a bodiless `502` from
  deep in the envelope assembly; it now gets the same `400` naming the
  offending field that every other rejected payload gets.

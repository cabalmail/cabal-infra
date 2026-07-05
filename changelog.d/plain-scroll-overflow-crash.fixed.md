- Fixed a crash in the Apple clients when opening a plain-text email. The
  in-message scroll reporter used an `Int.min` sentinel for the last reported
  offset, so the first scroll callback overflowed computing `offset -
  lastReportedPlainOffset`. The sentinel is now optional and non-finite scroll
  offsets are ignored.

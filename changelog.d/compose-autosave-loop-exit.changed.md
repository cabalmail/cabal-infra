- **A composer's autosave loops end with their composer.** The two loops
  that save a draft while it is being written (the local copy every 5 s,
  the server copy every 60 s) kept waking for the rest of the process if
  a composer went away without stopping them. Each now looks for its
  composer when it wakes and ends once it is gone. The intervals and the
  sleep are injected (`ComposeAutosaveTiming`) and the loops save through
  a small protocol, so the new `ComposeAutosaveTests` step the loops
  instead of waiting them out. A composer whose scene goes to the
  background also writes its local copy at once rather than at the next
  5 s tick (`ComposeAutosaveLoops.flush()`), and only while the loops are
  running, so a draft that was sent, discarded or handed to a window is
  not written back.

- Apple: **A discarded draft could be reopened and sent.** Discarding a draft
  that had been opened from the Drafts list expunged the server copy but told
  neither the list nor the reader, so the row stayed and the reader kept
  rendering the thrown-away draft — and Edit Draft on it reopened the whole
  message with Send live, which delivered. Cancelling a resumed draft whose
  body had been emptied dropped its server copy just as quietly. Both exits
  now prune the rows they retired and let the reader go.

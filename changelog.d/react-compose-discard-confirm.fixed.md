- **Compose no longer silently drops content typed before a From address
  is picked.** The autosave path is gated by an address (the server
  rejects `/save_draft` from unauthorized senders), so a compose opened
  fresh — which starts with no From — could accumulate typed content
  that autosave couldn't persist and close-flush couldn't rescue. Close
  now shows a confirm dialog when there is unsaveable content, so the
  user can go back and pick a From (which lets autosave take over) or
  explicitly discard.

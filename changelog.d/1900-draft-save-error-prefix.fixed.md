- Apple: **A failed draft save no longer says a send failed.** Saving a
  draft to the server reported "Couldn't save draft: Send failed: …" on
  every failure but an offline one, an expired session or a maintenance
  window — the compose surface wrote the reason with the send's lead baked
  in, and the save path prefixed its own on top. The leads sit with their
  operation now, so a failed save reads "Couldn't save draft: The server
  couldn't complete that request (500)." and a failed send is unchanged.

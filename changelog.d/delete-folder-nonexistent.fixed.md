- **Describable answer when a folder can't be deleted.** Deleting a folder
  that is already gone (removed by another client, or never there) returned a
  bodiless 502 the client could say nothing about. The API now answers 404
  naming the folder, maps any other IMAP-level failure to a 500 with a real
  message, and the folder rail shows what the API said instead of its generic
  line.

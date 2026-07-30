- **Clean 404 when a message is no longer in the folder.** Requesting a message
  whose UID has been expunged (moved, deleted, or emptied from Trash by another
  client) and whose body was never cached raised a `KeyError` inside the shared
  message loader, which API Gateway turned into a bodiless 502. `fetch_message`,
  `fetch_attachment`, `list_attachments`, and `fetch_inline_image` now return a
  404 naming the folder, so clients can tell "this message is gone, refresh the
  folder" from "the server is broken".

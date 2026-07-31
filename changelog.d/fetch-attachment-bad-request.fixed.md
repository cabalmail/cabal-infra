- **Clean 400 from `fetch_attachment` for a malformed request.** A missing or
  non-integer `filename`/`index`/`folder`/`id` used to escape the handler as an
  unhandled exception and reach the client as a bodiless 502 reading "Internal
  server error", so a caller could not tell a bad request from a broken server.
  The handler now validates its query string the way its `fetch_inline_image`
  sibling already did.

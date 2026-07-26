- **Creating a folder that already exists.** The API turned the server's
  rejection into an unhandled exception, so the request failed as a 502 with a
  traceback and the web app had nothing it could show. It now answers 409 and
  names the folder ("A folder called qa0726 already exists"), any other
  IMAP-level create failure answers a describable 500, and the folder rail
  surfaces whichever message the API sent instead of a generic line.

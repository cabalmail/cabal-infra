- Apple: **A message the server couldn't prepare no longer reads as a
  network failure.** When the server failed to prepare a message for
  download, the app tried to fetch the word "Error" as an address and
  showed "Couldn't reach the server. unsupported URL." It now says
  "Couldn't read the server's reply. fetch_message returned no presigned
  URL." without the extra request, and a sender logo that fails the same
  way is looked up again later instead of staying blank.

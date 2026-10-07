- Apple: **A cancelled request no longer reads as a network failure.** When
  the app itself cancelled a request (a sheet or window closed while it was
  loading), the request was reported as "Couldn't reach the server.
  cancelled." It now reads as cancelled, and a message whose loading is
  cancelled goes back to its spinner instead of an error with Retry. A
  launch whose window closes while it is starting still uses the saved
  server settings, as before.

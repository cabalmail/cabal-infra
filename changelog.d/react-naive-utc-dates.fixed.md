- **Message timestamps in the web app.** Envelope dates arrive from the API as
  naive UTC, and the browser was parsing them as local time, so every reader
  header and every relative age in the message list was off by the viewer's UTC
  offset — a message sent moments ago could read as hours in the future, and
  yesterday evening's mail showed today's date. Naive date-times are now pinned
  to UTC before formatting; values that carry a zone are untouched.

- Apple: **A message list left open offline stops retrying every 2
  seconds.** The list checks its folder for new mail by polling the
  server. When the server could not be reached, it tried again every 2
  seconds for as long as the list stayed on screen. It now waits longer
  after each failed try, up to a minute, and resumes its normal checks as
  soon as the server answers.

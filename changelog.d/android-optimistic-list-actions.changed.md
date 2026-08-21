- Android: **Instant message-list actions.** Swipe-to-dispose, move,
  purge, and read/flag changes now update the message list, filter pills,
  and counts immediately instead of waiting for the server, from the list,
  the reader, and search results alike. On the rare server-side failure
  the list surfaces the error and reconciles by refetching, and background
  polling holds off while a change is still being confirmed so it cannot
  resurrect a row the user watched leave.

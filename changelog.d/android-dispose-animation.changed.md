- Android: **Disposed rows animate out of the list.** The optimistic
  removal after a swipe-dispose, move, or purge was instantaneous, abrupt
  enough for the eye to miss. The departing row now fades out over a
  quarter second while the rows below glide up to close the gap, in both
  the message list and search results. Rows still appear instantly; only
  removal animates.

- Apple: **Feed site data is cleared on sign-out and after any sync.** The
  per-feed website data an article view keeps (cookies, publisher logins)
  survived sign-out, and when a feed was unsubscribed on another device it
  was cleared only if the sync that noticed happened to be a sidebar
  refresh. Removed feeds are now remembered until their data is cleared,
  whichever sync noticed, and signing out clears every feed's data.

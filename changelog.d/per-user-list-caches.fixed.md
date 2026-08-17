- **Web app: cached folder and address lists no longer leak between
  accounts on a shared browser.** The localStorage caches are now keyed
  per user and swept at login as well as logout, so signing in as a
  different account fetches that account's data instead of serving the
  previous user's cache (which login only cleared if the previous user
  had used the Logout button).

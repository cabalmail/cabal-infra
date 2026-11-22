- Apple: **Signing in on another server no longer inherits the last
  server's mail.** After a session expired at launch (or the app was force
  quit), signing in with the same username on a different server kept the
  last server's saved mail on screen offline and sent its unsent mail
  through the new server. A different server now counts as a different
  account, so its sign-in starts from an empty cache; the same server
  retyped with `https://`, spaces or capitals is still the same account.
  The comparison is one Kit type, `AccountIdentity` (the server
  normalized, the username exact). A sign-in that arrives while a session
  is already signed in is now refused instead of replacing that session
  without ending it; no screen offers one, and switching accounts stays
  Sign Out, then Sign In (#2559, #2560).

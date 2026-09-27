- Apple: **A session that expires while the app is running now signs you
  out.** The client kept serving cached mail and Settings ▸ Account still
  read "Signed in" — only a relaunch ever noticed. The Kit now announces an
  expiry from the two places it is discovered (a refresh Cognito refuses, a
  401 that survives one), the app tears the session down once on that signal,
  and the sign-in form says why you are looking at it.

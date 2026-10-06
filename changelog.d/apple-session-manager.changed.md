- Apple: **One connection per account.** Signing in, restoring the last
  session and signing out now live in one session manager, and
  notification actions, Siri and Shortcuts use the signed-in session's
  connection instead of opening their own. When one of them starts the app
  in the background, the connection it opens is the one the app then uses,
  so two can no longer both retry a message waiting in the Outbox. Nothing
  else should look or behave differently; anything that does is a bug
  worth reporting.

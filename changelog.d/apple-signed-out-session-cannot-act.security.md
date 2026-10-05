- Apple: **A signed-out session can no longer act as the next account.**
  Work still running from a session when you signed out (on a slow
  connection, a message still loading, for example) could send its next
  request with the credentials of the account that signed in after it, such
  as marking that account's message with the same number in the same folder
  read. A session that has signed out now sends nothing more.

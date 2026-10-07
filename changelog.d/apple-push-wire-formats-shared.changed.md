- Apple: **One shared definition for the push message reference.** No
  visible change. A new-mail push names its message with a small
  reference, and the server's reply when the notification asks for the
  sender and subject carries the message's confirmed number. The
  notification extension, the app and the Mac's own notifications each
  spelled those two formats separately; they now share one definition,
  with tests for the cases where the push carries no number or no message
  ID. Nothing should look or behave differently; anything that does is a
  bug worth reporting.

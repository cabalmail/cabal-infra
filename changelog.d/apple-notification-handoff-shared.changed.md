- Apple: **One shared definition for the notification hand-off.** No
  visible change. The notification extension, which turns "New mail" into
  the sender and subject, used to keep its own copy of the names and token
  format the app uses to hand it the server address and sign-in, so a
  rename on one side would have quietly turned every notification back
  into "New mail". Both now read them from one small shared module, and a
  test pins each value. Nothing should look or behave differently;
  anything that does is a bug worth reporting.

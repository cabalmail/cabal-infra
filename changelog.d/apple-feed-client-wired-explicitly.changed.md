- Apple: **Feeds get their server connection directly.** No visible change.
  The app used to find its feed client by checking whether the mail API
  client happened to be one too, so a different mail client would have
  switched Feeds off without an error. The feed client is now passed in
  where the app sets up its session, and the feed sync is built from that
  same client.

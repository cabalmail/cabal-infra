- Apple: **Siri and the feed screens no longer read out a server's raw
  reply.** When a request failed with a server error, a Siri or Shortcuts
  action (Check Inbox, create an address) and the feed sheets and sidebar
  showed the reply itself: JSON such as `{"message": "Internal server
  error"}`, a whole HTML error page, or nothing at all. They now say the
  same sentence the rest of the app does, such as "Internal server error."
  or "The server couldn't complete that request (502)."

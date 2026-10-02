- Apple: **A session that expires at launch signs you out reliably.** The
  app only began listening for an expired session a moment after it
  started a session, and the expiry signal is not replayed. A refusal that
  landed in that gap, most likely at launch while the app was still busy
  starting up, was missed, and the app could stay in the mail shell with
  Settings ▸ Account reading "Signed in". The listener is now in place
  before the session goes live, so a refusal at any point signs you out
  with the "Your session expired" explanation.

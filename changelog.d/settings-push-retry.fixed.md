- Apple: **A flag created offline is kept.** A change in Settings that
  the app could not send, a new or deleted flag among them, is now sent
  again when the connection returns, when the app comes back to the
  front, and at the next launch, even if you quit the app first. Before,
  it waited for your next change to a setting, and a relaunch could undo
  it. A feed item given a new flag before the server had it lost the
  flag again, with no message, once the connection returned; now the app
  sends the new flag first and the item keeps it.

- Apple: **A flag created offline is kept.** A change in Settings that
  the app could not send, a new flag among them, is now sent again when
  the connection returns and when the app comes back to the front; a new
  flag is also sent at the next launch, even if you quit the app first.
  Before, it waited for your next change to a setting. A feed item given
  a new flag before the server had it lost the flag again, with no
  message, once the connection returned; now the app sends the new flag
  first and the item keeps it.

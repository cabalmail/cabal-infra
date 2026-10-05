- Apple: **Private links stop leaving the address in Safari's history.**
  "Open in Private Window" hands the browser a redirector page and relied on
  the extension deleting that page's history entry afterwards -- but Safari's
  extension engine implements no history API, so on Safari the entry stayed,
  with the link readable in it. The macOS app now gives Safari an opaque token
  instead and the extension gets the address from the app's shared container,
  so any entry left behind records that a private window was opened and not
  what was opened. Chrome, which does delete the entry, is unchanged.

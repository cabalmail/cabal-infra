- Fixed navigation-cursor restore on the Apple clients: `get_nav_state`
  crashed with a `Decimal is not JSON serializable` error on every read, so
  clients silently fell back to INBOX on launch instead of restoring the last
  folder/message. Positions were being saved all along; only the read was
  broken.

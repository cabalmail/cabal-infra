- Apple: **Contacts buttons in compose no longer sit there looking live.** The
  picker button beside To / Cc / Bcc rendered at full accent strength even when
  it was inert, and it went inert whenever the contact list came back empty —
  including when that was because Contacts access had never been granted, with
  no way to grant it from compose. It now asks for access when access has never
  been decided, opens the system privacy pane when access was refused, and dims
  only in the one case where there is genuinely nothing to pick.

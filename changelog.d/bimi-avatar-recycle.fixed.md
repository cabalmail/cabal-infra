- Fixed sender BIMI logos occasionally appearing on the wrong message
  rows in the Apple clients' inbox, most often near the top as new mail
  arrived. A row recycled to a different sender while its predecessor's
  logo lookup was still in flight could paint the stale logo; the avatar
  load now discards results once its row has moved on to another sender.

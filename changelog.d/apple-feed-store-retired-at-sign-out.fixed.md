- Apple: **Feeds from the account that signed out no longer show for the
  next one.** A feed refresh still running when you signed out could write
  that account's feeds and items back after the sign-out had cleared them,
  so the next account to sign in on the same device briefly saw them in its
  Feeds sidebar until its own first refresh finished. The signed-out
  session's feed store now takes no further writes (#1937).

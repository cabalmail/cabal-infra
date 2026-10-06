- Apple: **Sender logos come back after an offline start.** A logo lookup
  that failed because the app was offline was remembered as "no logo" until
  the app was relaunched, even across signing out and back in. A failed
  lookup is now asked again the next time that sender's avatar is drawn, so
  logos return as rows are scrolled into view or a message is opened.

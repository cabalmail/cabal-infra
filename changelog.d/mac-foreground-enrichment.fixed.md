- Apple: **Enriched Mac notifications while the app is running.** macOS
  kills notification service extensions before they run (a long-standing
  platform defect), so Mac pushes only ever showed the generic "New mail".
  The Mac app now does the enrichment itself while it is open but not
  focused — sender, subject, and snippet, with Open / Mark as Read /
  Archive acting on the right message — and while it is focused no banner
  shows (the app already displays the mail). Notifications still show the
  generic "New mail" when the app is quit; the extension stays shipped so
  a future macOS fix restores enrichment there too.

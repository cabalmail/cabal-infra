- **No more sendmail restart on the IMAP tier for a settings change that
  adds or deletes no flag.** Once an account had a flag list, nearly
  every settings change made in an Apple or Android app (a theme, a mail
  folder's Unread pill) carried that list, and `set_preferences` told the
  IMAP tier to recompile the mail rules whether or not the list had
  changed; a recompile ends by restarting sendmail. It now does so only
  when a flag of the user's own is added or deleted, the one change to
  the list the rule compiler reads (#2450).

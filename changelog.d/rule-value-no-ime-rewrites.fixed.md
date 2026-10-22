- Android: **Rule values keep what you typed.** A Subject or Body condition
  value is a literal substring, but Gboard went on auto-correcting it as
  each word ended and the editor's auto-save carried the rewrite to the
  server, so the rule stopped matching what was meant. The value now edits
  under an input-type variation the keyboard declines to correct; clearing
  the auto-correct flag and then refusing suggestions outright were both
  measured being corrected anyway.

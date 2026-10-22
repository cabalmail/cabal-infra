- Android: **Rule values keep what you typed.** A Subject or Body condition
  value is a literal substring, but Gboard went on auto-correcting it as
  each word ended and the editor's auto-save carried the rewrite to the
  server, so the rule stopped matching what was meant. The field now refuses
  IME suggestions outright (`TYPE_TEXT_FLAG_NO_SUGGESTIONS`), which
  `autoCorrectEnabled = false` alone never asked for.

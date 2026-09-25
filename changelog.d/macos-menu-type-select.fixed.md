- Apple: **Type-to-select picks the address you typed again.** On macOS,
  typing more than one character in Settings ▸ Composing ▸ Default From, or
  in the compose From menu, moved the highlight to a *different* address —
  and Return committed it, so typing an address in full could set Default
  From to another one or send from it. The zero-width breaks that keep a
  wrapped address from sprouting a hyphen it does not contain are also what
  AppKit compares typed characters against, and they sort below every
  letter. AppKit menu rows never wrap, so they draw the plain address now;
  iPhone, iPad and Vision Pro rows, which do wrap, keep the breaks.

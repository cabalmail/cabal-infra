- **A flag is in the palette or it is not.** `/set_flag`,
  `/rss_set_item_state` and the mail-rules compiler no longer read an
  entry's `enabled`. A custom flag whose entry is stored as disabled can
  be added to a message or a feed item, and a rule that sets it runs
  instead of being skipped. A slot that is not in the palette is refused
  as before (`flag_not_in_palette`), so a deleted flag still cannot be
  added and still skips its rules. This is the server's part of taking
  the Enabled switch off custom flags; the clients follow.

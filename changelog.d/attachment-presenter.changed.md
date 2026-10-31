- **Reader attachments open through one presenter.** The chips under a
  message's header ask the reader's attachment presenter
  (`presentsAttachments()`, a `Platform/` adapter) to open a file,
  ready for the Message menu's Attachments submenu to share it; the
  strip drops its six platform conditionals, and which attachments open
  as an invitation is a tested rule (`AttachmentOpenRoute`).

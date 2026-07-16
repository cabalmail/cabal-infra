- Apple: **Attachments carrying a Content-ID now appear in the reader.**
  An attached image whose part also carried a `Content-ID` (Gmail stamps one
  on every attached image) was mis-classified as an inline image and hidden
  from the attachment strip, so it could be neither viewed nor downloaded on
  iOS and macOS. Attachment listing and inline-image resolution are now two
  independent decisions, matching the web client: a part flagged
  `Content-Disposition: attachment` always gets an attachment chip, even when
  it also resolves a `cid:` reference in the body.

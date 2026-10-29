- **Inline images in composed mail.** `/send` and `/save_draft` take an
  optional `content_id` on an attachment. An image the HTML body shows
  as `<img src="cid:<id>">` goes beside the HTML in a
  `multipart/related` part with that Content-ID instead of being
  attached. Anything that can't go inline (an id a reader couldn't
  fetch or the header couldn't carry as written, a non-image, an id the
  HTML doesn't show, a text-only body, a repeated id) is attached as
  before, and a request without the field composes exactly as before.

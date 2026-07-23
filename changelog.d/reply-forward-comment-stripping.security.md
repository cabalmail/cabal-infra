- **Hardened HTML comment stripping when quoting a message for reply/forward.**
  The reply/forward body prep used a regex loop to strip `<!-- -->` markers
  before splicing the quoted body into the compose editor; CodeQL flagged it
  as an incomplete multi-character sanitization, since regex removal of one
  comment marker can reassemble surrounding text into a new one. It now
  parses the quoted body with the browser's HTML parser and removes actual
  comment nodes instead.

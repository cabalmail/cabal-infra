- Apple clients: inline `cid:` images (e.g. USPS Informed Delivery
  mailpiece scans) now render in the message body. They were rewritten to
  temp `file://` URLs, which the body web view — loaded with an opaque
  origin — is not allowed to fetch; they are now embedded as `data:` URIs.

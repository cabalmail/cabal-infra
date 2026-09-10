- **OPML import and export (phase 4 of the RSS plan).** `/rss_opml_import`
  adds every feed in an OPML document, additively: the outline tree becomes
  folders (reusing same-named ones), feeds already followed are reported
  rather than duplicated, and unknown feeds are created from the document's
  own titles and handed to the fetcher so a large export fits one request.
  `/rss_opml_export` returns the caller's folders and subscriptions as
  OPML 2.0 that round-trips into Feedly, NetNewsWire, and Reeder. Also:
  the canonical-URL rule no longer touches trailing slashes anywhere but
  the root (a publisher's redirect decides), and unsubscribe deletes
  per-item state before the subscription row.

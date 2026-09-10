- **RSS root-level subscriptions report an empty `folder_id`.** The API
  passed its internal root sentinel through, so subscriptions outside any
  folder carried `folder_id: "~root"` and the OPML export left them out.

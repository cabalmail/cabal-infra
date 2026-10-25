- **Four Apple-client doc comments now name files that exist.** The IMAP
  delimiter note cited the shared Lambda layer's `helper.py` path, deleted with
  the layer; `RawMessage` said MIME parsing happens outside `CabalmailKit`, in a
  `MessageDetailView.swift` that has since moved; the address view model mirrored
  a React `List.jsx` dropped when the left rail was rebuilt; and the endpoint-URL
  note pointed at an `apigw.tf` that never existed. Comments only, no code
  change.

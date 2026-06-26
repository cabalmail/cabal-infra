- Apple clients: fixed remote images failing to load after tapping "Show
  remote content" — the message web view reloaded on every SwiftUI update,
  cancelling slower in-flight image requests (e.g. USPS Informed Delivery
  mailpiece scans), so only the fastest one or two ever appeared. It now
  reloads only when the message content or remote-content policy actually
  changes.

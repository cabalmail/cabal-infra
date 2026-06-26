- Apple clients: the message body web view no longer reloads on every
  SwiftUI update (flag changes, attachment loads, folder polling); it
  reloads only when the content or remote-content policy actually changes.
  The prior churn could cancel in-flight remote image requests mid-load.

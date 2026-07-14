- Apple: **Notification actions update the open app immediately.** Mark as
  Read and Archive from a notification now refresh the running app's views
  right away instead of waiting for the next poll. (Also fixed the Mac
  notification extension's shared-keychain read — a macOS/iOS platform
  difference in group-less keychain searches — so extension-side enrichment
  works the moment macOS stops killing the extension at startup; see the
  companion entry for how Mac notifications get their content today.)

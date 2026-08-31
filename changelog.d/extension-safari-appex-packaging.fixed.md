- **Safari extension packaging.** The web bundle was copied into the app
  extension one directory too deep, so `manifest.json` never sat where Safari
  and App Store validation look for it, and the host app shipped without an
  icon. Both blocked the macOS App Store upload.

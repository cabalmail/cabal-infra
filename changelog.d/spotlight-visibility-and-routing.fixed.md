- Apple: **Spotlight results now appear on iOS and open Cabalmail on
  macOS.** Indexed messages were invisible in iOS Spotlight (iOS 17+
  requires a display name the entries didn't set), and on macOS clicking
  a result still opened Apple Mail — the system routes results typed
  `public.email-message` to the default mail handler no matter what the
  donating app declares, so entries are now donated under a neutral text
  type and macOS delivery goes through the AppKit continuation callback
  (SwiftUI's handler never fires there). The index rebuilds itself once
  on first launch after updating.

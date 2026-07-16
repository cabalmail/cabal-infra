- Apple: **mailto: links open a pre-filled compose from any screen
  (iOS/iPadOS/visionOS).** A `mailto:` tap used to be silently dropped
  whenever the message list wasn't the visible view — on iPhone the
  compose sheet was anchored to that list, which cannot present from a
  background tab, so the app just showed its last state (an App Review
  rejection for the default-mail-app request) and the orphaned compose
  then ambushed the user on their next visit to the Mail tab. Compose
  requests are now received at the signed-in root, which is visible in
  every tab, folder, and modal state. A `mailto:` arriving while a
  draft is already open no longer replaces the draft mid-typing; it
  opens once that draft is closed.

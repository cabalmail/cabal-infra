- Android: **Instant new-mail push notifications.** Where Google Play
  services is available, new mail now raises a notification within seconds
  via FCM instead of waiting for the 15-minute background check (which
  remains as the fallback). The push itself is content-free — sender and
  subject are fetched from the mail server by the app, so Google's
  infrastructure never sees message content. Registration is tied to the
  existing notifications opt-in in Settings and is removed on sign-out.
  Builds without Firebase config (all CI builds) are unaffected. Phase 3 of
  docs/1.x/android-push-notifications.md.

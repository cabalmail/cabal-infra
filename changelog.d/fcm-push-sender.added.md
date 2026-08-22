- **FCM sender in the push-notification pipeline.** `push_dispatch` now
  routes each registered device token to its platform's sender — Apple rows
  to APNs, `android` rows to Firebase Cloud Messaging (HTTP v1, data-only,
  content-free wake signals) — and `/push_register` / `/push_deregister`
  accept the Android app's bundle id and FCM token format. The credential
  lives at `/cabal/fcm/service_account` (Terraform-seeded placeholder,
  operator-provisioned); until it is seeded, Android sends drop cleanly
  with Apple delivery untouched, mirroring the APNs posture. Adds a
  `Platform` dimension to the `Cabal/Push` CloudWatch metrics. Phase 1 of
  docs/1.x/android-push-notifications.md.

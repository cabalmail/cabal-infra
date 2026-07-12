- **Push notifications for the Apple clients.** New mail now raises an APNs
  notification on iOS within seconds of delivery, without Apple's
  infrastructure seeing message content: procmail spools a content-free
  wake signal per local delivery (forwarded to `cabal-push-queue` by a
  credential-holding drain daemon, keeping AWS credentials away from the
  per-user delivery agents), the new
  `push_dispatch` Lambda fans it out to the user's registered devices
  (`cabal-push-tokens`, managed by the new `/push_register` and
  `/push_deregister` endpoints), and the app's Notification Service
  Extension enriches the alert on-device via the new `/push_envelope`
  endpoint — falling back to a generic "New mail" when enrichment cannot
  complete. Notifications carry Open / Mark as Read / Archive actions; the
  enqueue is a best-effort side effect that never blocks or fails mail
  delivery, and spam-filed messages do not notify. Inert until an operator
  provisions an APNs auth key (see docs/push-notifications.md).

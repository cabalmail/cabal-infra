- Apple: **Signing out no longer risks leaving queued mail behind.** If a
  queued message was being retried at the moment you signed out and that
  retry failed, it could be written back to the device's outbox after
  sign-out had cleared it, and then be sent by the next account to sign in
  on the device. A message removed from the outbox now stays removed.

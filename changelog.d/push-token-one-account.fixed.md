- **Another account's notifications after a failed sign-out.** If signing
  out could not reach the server (offline, say), the device stayed
  registered for that account's pushes, and after another account signed
  in on the same device those notifications kept arriving, with Mark as
  Read and Archive acting on the new account's mail. Registering a device
  for push now removes any other account's registration of it, using a
  new `by_device_token` index on `cabal-push-tokens`.

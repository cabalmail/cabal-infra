- **Weekly push-token garbage collection.** A scheduled Lambda
  (`push_token_gc`) reaps device-token rows idle for 90+ days — the backstop
  for tokens that neither APNs-rejection pruning nor sign-out deregistration
  can reach (a device that stopped launching the app whose user receives no
  mail). A reaped device transparently re-registers on its next app launch.

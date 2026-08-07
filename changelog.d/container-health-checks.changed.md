- **In-container health checks for the imap and smtp-out tiers.** With
  their public NLB listeners gone, these tiers are no longer probed by
  the load balancer; each task definition now checks its own service
  ports (143; 465 and 587) directly. The probe gates deployments (the
  circuit breaker rolls back a task that never becomes healthy) and
  replaces a hung-but-running task in steady state. Inbound relay (25)
  still uses the NLB's own health checks.

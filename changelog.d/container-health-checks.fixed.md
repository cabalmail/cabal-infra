- **Health checking restored for the imap and smtp-out tiers.** Removing
  the public IMAP and submission listeners silently ended the NLB's TCP
  probes of those tiers - a target group with no listener is never
  health-checked (`Target.NotInUse`) - so a task that started but never
  listened would have passed deploys and never been replaced. Each task
  definition now carries an in-container TCP probe of its service ports
  (143; 465 and 587), restoring the deployment gate (circuit-breaker
  rollback of a never-healthy task) and hung-task replacement. Inbound
  relay (25) still uses the NLB's own health checks.

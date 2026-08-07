- **Deploys to the imap and smtp-out tiers un-bricked.** ECS refuses
  `UpdateService` while a service references a target group with no
  associated load balancer, so after the public listener removal every
  deploy to those tiers failed (`InvalidParameterException` in the
  post-apply service roll). The services' dead load-balancer wiring and
  the three detached target groups (imap, submission, starttls) are now
  removed - an in-place service update, no replacement - along with the
  imap service's load-balancer grace period, whose role the container
  health check's `startPeriod` already covers.

- Bad IMAP deploys now fail fast and roll back: the IMAP service's
  health-check grace period drops from 600s to 120s and a deployment
  circuit breaker returns the service to the last working revision
  instead of letting a broken task thrash the single-task service.
  deploy-ecs-service.sh now asserts the service stabilized on the
  revision it registered, so a rolled-back deploy fails CI instead of
  reporting success. Phase 2 of docs/0.10.x/imap-deploy-downtime-plan.md.

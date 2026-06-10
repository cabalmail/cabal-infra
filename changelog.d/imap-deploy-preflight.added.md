- IMAP deploys now pre-flight the new image before touching the running
  service: deploy-ecs-service.sh runs the freshly registered revision as
  a one-shot task with PREFLIGHT=1 (the entrypoint exercises secrets,
  EFS, Cognito, DynamoDB, and the sendmail compile, then exits without
  starting services) and aborts the deploy while the old task is still
  serving if it fails. The planned-maintenance flag is now raised by the
  deploy script only after the preflight passes, so a failed deploy
  never 503s the admin app at all. Costs ~30-60s per successful deploy;
  saves the full outage window on a bad image. Phase 5 of
  docs/0.10.x/imap-deploy-downtime-plan.md.

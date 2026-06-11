- IMAP deploys pre-pull the freshly pushed image onto the cluster's
  container instance(s) via SSM Run Command while the old task is still
  serving, so the roll no longer pays the 30-60s cold layer download
  inside its zero-task window. Fail-soft: a failed or unauthorized
  pre-pull logs a warning and the deploy proceeds on the previous slow
  path. Phase 4 of docs/0.10.x/imap-deploy-downtime-plan.md.

# IMAP deploys: maintenance window, pre-flight, rollback

The IMAP service is hard-capped at one ECS task (Dovecot has Maildir-over-EFS concurrency issues), so every IMAP image roll has a true zero-task window: the old container stops before the new one starts. The deploy path (`.github/scripts/deploy-ecs-service.sh`, driven by `app.yml`) wraps that window in three protections:

1. **Pre-flight.** The new task-definition revision first runs as a one-shot task with `PREFLIGHT=1` (entrypoint validation only). A failing pre-flight aborts the deploy with the old task still serving and the maintenance flag never raised. `PREFLIGHT_DISABLE=1` skips it.
2. **Planned-maintenance flag.** Immediately before the roll, CI writes `/cabal/maintenance/imap` in SSM (`maintenance-flag.sh set`). `get_imap_client()` in the API Lambdas consults it and returns a friendly `503` + `Retry-After` instead of dialing a dead server; cache-served reads (S3 message-cache hits) keep working. The **new container** clears the flag once Dovecot serves (`docker/shared/clear-maintenance.sh`) — CI never clears it; a TTL baked into the flag (default 1200 s) is the backstop if the deploy job dies. Flag reads fail open: any SSM error means "not in maintenance".
3. **Stability wait.** The script waits for `services-stable`, so a completed `app.yml` run means the new image is actually serving.

## What an operator (and users) see

- Clients show a "planned maintenance" message for roughly 1–2 minutes per IMAP roll. That is normal.
- Sends are unaffected: `/send` is SMTP-first and does not touch IMAP; inbound mail queues durably on smtp-in ([mail-queues.md](./mail-queues.md)).
- To distinguish a stuck deploy from a real outage, read the flag: `aws ssm get-parameter --name /cabal/maintenance/imap`. Active flag past its `until` epoch, or errors with no flag set, mean a real problem. `maintenance-flag.sh clear` exists for manual recovery; the normal path never needs it.

Design history: [0.10.x/imap-deploy-downtime-plan.md](./0.10.x/imap-deploy-downtime-plan.md).

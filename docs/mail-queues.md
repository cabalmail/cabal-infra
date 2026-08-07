# Durable relay queues

Both SMTP tiers persist sendmail's deferred-mail queue (`/var/spool/mqueue`) on the mailstore EFS filesystem, so a task replacement cannot destroy queued mail. Each tier has its own EFS access point (`/smtp-queue` for smtp-out, `/smtp-in-queue` for smtp-in — see `terraform/infra/modules/efs/main.tf`), and every task of a tier mounts the same queue directory. This is sendmail's classic shared-NFS queue pattern: queue files are claimed with fcntl locks, so whichever task's queue runner scans next picks up work a replaced task left behind. Only the MTA queue is persisted; `clientmqueue` stays on the container filesystem.

Why it matters on each tier:

- **smtp-out**: outbound mail deferred by a remote MX (greylisting, transient 4xx) survives deploys and retries until delivery or queue timeout.
- **smtp-in**: sendmail is store-and-forward — smtp-in answers `250` *before* relaying to the imap tier, so mail deferred while imap is mid-deploy sits in smtp-in's queue with delivery already promised. Before this queue was persisted (0.11.26), that window silently dropped accepted mail.

## Shutdown and retry timing

- Supervisord gives sendmail `stopwaitsecs=110` inside the tiers' 120-second ECS stop grace, so an in-flight delivery attempt can finish before the task dies; anything still queued is drained by a sibling or successor task.
- `reconfigure.sh` restarts sendmail on a fallback interval (`RECONFIGURE_INTERVAL`, default 900 s) as a safety net for missed SNS/SQS reconfiguration events. A sendmail restart roughly every 15 minutes in the tier logs is **by design**, not a crash loop — and each restart also kicks the queue runner.

## Verification

The behavior is verified end-to-end (park a message with the SMTP sinkhole's forced 4xx, replace the task, watch the successor deliver) by the runbook in [testing/queue-persistence.md](./testing/queue-persistence.md). Design history: [0.9.x/smtp-out-queue-persistence-plan.md](./0.9.x/smtp-out-queue-persistence-plan.md).

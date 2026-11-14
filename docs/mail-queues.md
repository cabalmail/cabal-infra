# Durable relay queues

Both SMTP tiers persist sendmail's deferred-mail queue (`/var/spool/mqueue`) on the mailstore EFS filesystem, so a task replacement cannot destroy queued mail. Each tier has its own EFS access point (`/smtp-queue` for smtp-out, `/smtp-in-queue` for smtp-in — see `terraform/infra/modules/efs/main.tf`), and every task of a tier mounts the same queue directory. This is sendmail's classic shared-NFS queue pattern: queue files are claimed with fcntl locks, so whichever task's queue runner scans next picks up work a replaced task left behind. Only the MTA queue is persisted; `clientmqueue` stays on the container filesystem.

Why it matters on each tier:

- **smtp-out**: outbound mail deferred by a remote MX (greylisting, transient 4xx) survives deploys and retries until delivery or queue timeout.
- **smtp-in**: sendmail is store-and-forward — smtp-in answers `250` *before* relaying to the imap tier, so mail deferred while imap is mid-deploy sits in smtp-in's queue with delivery already promised. Before this queue was persisted (0.11.26), that window silently dropped accepted mail.

## Shutdown and retry timing

- Supervisord gives sendmail `stopwaitsecs=110` inside the tiers' 120-second ECS stop grace, so an in-flight delivery attempt can finish before the task dies; anything still queued is drained by a sibling or successor task.
- `reconfigure.sh` restarts sendmail on a fallback interval (`RECONFIGURE_INTERVAL`, default 900 s) as a safety net for missed SNS/SQS reconfiguration events. A sendmail restart roughly every 15 minutes in the tier logs is **by design**, not a crash loop — and each restart also kicks the queue runner.

## If sendmail stops

Supervisord restarts sendmail whenever it exits, with one exception: a program that exits within `startsecs` (5 s) of its start four times running is given up on (`gave up: sendmail entered FATAL state` in the tier log) and is not started again. `reconfigure.sh` restarts sendmail by killing it, so restarts that come back to back are how a tier could get there. Each tier has a signal that turns a missing sendmail into a task replacement:

- **imap**: the container health check connects to Dovecot's port 143 and, once `/run/sendmail-ready` exists, looks for a sendmail process. Three failed checks, ten seconds apart, mark the task unhealthy and ECS replaces it. Mail that arrives meanwhile waits in smtp-in's queue.
- **smtp-out**: the container health check connects to both submission ports and looks for a sendmail process, every 30 seconds.
- **smtp-in**: the load balancer's check on port 25 fails, and ECS replaces a task its load balancer reports unhealthy.

The process is looked for twice, three seconds apart, because every restart leaves about a second with no sendmail running. On imap and smtp-out the signal is "a sendmail process exists", not "sendmail answers on port 25".

## Verification

The behavior is verified end-to-end (park a message with the SMTP sinkhole's forced 4xx, replace the task, watch the successor deliver) by the runbook in [testing/queue-persistence.md](./testing/queue-persistence.md). Design history: [0.9.x/smtp-out-queue-persistence-plan.md](./0.9.x/smtp-out-queue-persistence-plan.md).

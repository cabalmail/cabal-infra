# Cabalmail alert runbooks

Short on-call runbooks for every alert in [docs/0.7.0/monitoring-plan.md](../../0.7.0/monitoring-plan.md) Phases 1-3. Each file follows the same shape:

1. **What this means** — what condition fired the alert.
2. **Who/what is impacted** — user-visible effect.
3. **First three things to check** — start here on a page.
4. **Escalation** — what to do if the first three don't resolve.

When a Pushover or ntfy push includes a `Runbook:` link, it points to one of these files on `main`.

## Sources of alerts

| Source | Routing | Phase |
| --- | --- | --- |
| Uptime Kuma monitors | Webhook → `alert_sink` Lambda | 1 |
| Self-hosted Healthchecks | Webhook → `alert_sink` Lambda | 2 |
| Prometheus rules → Alertmanager | Webhook → `alert_sink` Lambda | 3 |
| `alert_sink` Lambda | Pushover (critical) + ntfy (critical + warning) | 1 |

## Index

### Probe failures (Kuma TCP/HTTP, Prometheus blackbox)

- [probe-failure.md](./probe-failure.md) — any Kuma or blackbox probe down.
- [cert-expiring.md](./cert-expiring.md) — ACM cert or blackbox-probed cert nearing expiry.

### AWS service alerts (Prometheus rules over `cloudwatch_exporter`)

- [lambda-5xx-spike.md](./lambda-5xx-spike.md)
- [lambda-throttles.md](./lambda-throttles.md)
- [lambda-errors.md](./lambda-errors.md)
- [dynamodb-throttling.md](./dynamodb-throttling.md)
- [dynamodb-system-errors.md](./dynamodb-system-errors.md)
- [efs-burst-credits-low.md](./efs-burst-credits-low.md)
- [container-restart-loop.md](./container-restart-loop.md)

### Host alerts (Prometheus rules over `node_exporter`)

- [node-high-cpu.md](./node-high-cpu.md)
- [node-high-memory.md](./node-high-memory.md)
- [node-disk-space-low.md](./node-disk-space-low.md)

### Heartbeats (missed Healthchecks pings)

- [heartbeat-certbot-renewal.md](./heartbeat-certbot-renewal.md)
- [heartbeat-aws-backup.md](./heartbeat-aws-backup.md)
- [heartbeat-dmarc-ingest.md](./heartbeat-dmarc-ingest.md)
- [heartbeat-ecs-reconfigure.md](./heartbeat-ecs-reconfigure.md)
- [heartbeat-cognito-user-sync.md](./heartbeat-cognito-user-sync.md)
- [heartbeat-quarterly-review.md](./heartbeat-quarterly-review.md)

## After the alert resolves

The plan's tuning discipline applies: after every page, record on the corresponding GitHub issue (or open one) whether the threshold was right, too sensitive, or too loose. Thresholds live in code:

- Prometheus: [docker/prometheus/rules/alerts.yml](../../../docker/prometheus/rules/alerts.yml)
- Kuma & Healthchecks: in the UI today; will move to IaC in Phase 4 §3.

Aim for **zero false pages in a typical week** (see monitoring-plan.md § "Tuning discipline"). If a runbook's "first three things" never apply, fix the runbook in the same PR that fixes the alert.

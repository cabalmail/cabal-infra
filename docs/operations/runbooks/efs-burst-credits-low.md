# Runbook: EFSBurstCreditsLow

Fired by Prometheus rule [`EFSBurstCreditsLow`](../../../docker/prometheus/rules/alerts.yml) — `BurstCreditBalance` below 20% of baseline for 1 h.

## What this means

The EFS file system is on **bursting throughput mode** and has spent down its accumulated credits. Once credits hit zero, EFS throttles I/O to the file system's baseline rate (which scales with stored size — small file systems get very little baseline).

For Cabalmail, EFS holds:
- Mailstores (Maildir under `/home/<user>` for each Cognito user).
- Monitoring state (Kuma SQLite at `/uptime-kuma`, ntfy auth/cache at `/ntfy`, Healthchecks SQLite at `/healthchecks`, Prometheus TSDB at `/prometheus`, Grafana SQLite at `/grafana`, Alertmanager state at `/alertmanager`).

## Who/what is impacted

When credits run out:
- IMAP reads slow — Dovecot does many small file reads per folder list.
- Local delivery (sendmail → procmail → Maildir) slows; in extreme cases, deferred.
- Monitoring state writes block — Kuma stops persisting probe results, Prometheus drops scrapes.

## First three things to check

1. **Are we genuinely burning through credits, or is this a slow drain?**
   ```sh
   aws cloudwatch get-metric-statistics --namespace AWS/EFS --metric-name BurstCreditBalance \
     --dimensions Name=FileSystemId,Value=<fs-id> \
     --start-time $(date -u -v-24H +%FT%TZ) --end-time $(date -u +%FT%TZ) \
     --period 300 --statistics Average
   ```
   A steep drop in the last hour points to a runaway process. A linear drift over days means baseline > burst earnings — file system needs to grow or move to elastic mode.
2. **Who's driving I/O?** Check `MeteredIOBytes` per access point in the EFS console. If `/uptime-kuma` or `/prometheus` is dominating, the monitoring stack is the culprit (often Kuma writing 1-second probe results to SQLite — bump the monitor interval). If `/home` dominates, look for a stuck procmail or a brute-force on IMAP creating lots of failed-auth log writes.
3. **Is the file system size very small?** Bursting throughput baseline = file-system size × 50 KB/s. A 5 GB file system gets 250 KB/s baseline — easy to overrun. Either store dummy ballast or migrate to elastic throughput.

## Escalation

- **Quick fix, expensive**: switch to elastic throughput mode (`aws efs update-file-system --file-system-id <fs-id> --throughput-mode elastic`). Costs more but eliminates the throttle class entirely.
- **Cheaper, slower**: provisioned throughput at a fixed MiB/s. Predictable cost; needs sizing.
- **Free, slow**: identify and slow down the heaviest writer. Kuma's interval is the most common knob.
- This is `warning` severity. Once the file system is **at** zero credits and throttling, expect mail-delivery latency alerts to follow if any are configured (Phase 4 §2 adds these).

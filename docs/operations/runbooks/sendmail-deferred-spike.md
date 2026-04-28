# Runbook: SendmailDeferredSpike

Fired by Prometheus rule [`SendmailDeferredSpike`](../../../docker/prometheus/rules/alerts.yml) — more than 10 sendmail "stat=Deferred" log lines aggregated across all three mail tiers in the last 10 minutes, sustained for 15 minutes.

## What this means

Sendmail logs `stat=Deferred` whenever it parks a message in the queue rather than delivering immediately — typically on a 4xx response from a remote MX (graylisting, rate-limit) or a transient internal failure. A sustained rate above ~1/min is unusual for a single-operator Cabalmail instance.

## Who/what is impacted

The metric is summed across three log groups; the alert doesn't tell you *which* tier is deferring. The user impact differs by tier:

- **`smtp-out`**: outbound mail sits in the queue. Recipients on a graylisting provider see delivery delays of ~5-30 min, which is normal once and concerning if recurring. Sustained deferral means our reputation may be degraded.
- **`smtp-in`**: inbound mail can't be relayed to the IMAP tier (network or auth issue). Mail from outside accumulates remotely until peers give up (typically 4-5 days).
- **`imap`**: local delivery (LDA → procmail → Maildir) is failing. New mail accepted by smtp-in piles up in the IMAP tier's local queue until delivery succeeds or expires.

## First three things to check

1. **Which tier?** The metric has no tier dimension. Look at queue depth on each:
   ```sh
   for tier in imap smtp-in smtp-out; do
     echo "=== $tier ==="
     TASK=$(aws ecs list-tasks --cluster <cluster> --service-name cabal-$tier --query 'taskArns[0]' --output text)
     aws ecs execute-command --cluster <cluster> --task "$TASK" --container $tier --interactive \
       --command "/bin/sh -c 'mailq | tail -1'"
   done
   ```
   The tier with a non-trivial mailq is the offender.
2. **Why is it deferring?** Pull recent deferred reasons:
   ```sh
   aws logs tail /ecs/cabal-<tier> --since 30m --filter-pattern '"stat=Deferred"' | head -20
   ```
   Look at the `dsn=4.x.y` codes:
   - `4.4.x` → connectivity / MX issue
   - `4.7.x` → policy block (graylisting, SPF-soft-fail, IP reputation)
   - `4.5.x` → mail-system congestion at remote
3. **Is this a self-inflicted issue?** Check whether outbound DNS resolution from the smtp-out tier works (NAT instance issue produces a wave of `4.4.x` deferrals). Check `aws ec2 describe-instances --filters Name=tag:Name,Values=cabal-nat` for state=running.

## Escalation

- **Graylist storm on smtp-out**: if multiple recipients on the same provider (gmail, outlook) defer with `4.7.x`, our IP may be on a transient blocklist. Check <https://mxtoolbox.com/blacklists.aspx> with the smtp-out NAT public IP. Most blocklists self-clear in 24-48 h.
- **NAT instance issue**: replace the NAT instance via the ASG. Confirm by tailing `cabal-smtp-out` logs immediately after — deferrals should stop within minutes.
- **Local-delivery failure on imap**: check procmail config, mailbox quotas (none enforced today, but check disk space on EFS), and that the IMAP tier's user list is in sync with `cabal-addresses`. The `ecs-reconfigure` heartbeat covers user-sync; if it's missed, see [heartbeat-ecs-reconfigure.md](./heartbeat-ecs-reconfigure.md).
- **Inbound relay failure**: confirm the Cloud Map service `imap.cabal.internal` resolves from inside the smtp-in task and that the IMAP tier is accepting connections on port 25.
- This is `warning`. If deferrals tip into bounces, [`SendmailBouncedSpike`](./sendmail-bounced-spike.md) escalates to critical.

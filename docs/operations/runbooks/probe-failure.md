# Runbook: probe failure (Kuma or blackbox)

Fired by:
- Kuma monitors: IMAP TLS (993), SMTP relay (25), Submission STARTTLS (587), Submission TLS (465), Admin app HTTP, API round-trip (`/list`), ntfy server health.
- Prometheus rule [`BlackboxProbeFailure`](../../../docker/prometheus/rules/alerts.yml) (any blackbox target).

## What this means

A synthetic probe to a user-facing endpoint is failing. The probe is one of:
- **Mail port (993/25/587/465)** — the NLB-fronted mail-tier listener didn't accept a TCP/TLS handshake within the timeout.
- **Admin app (`https://admin.<control-domain>/`)** — CloudFront → S3 returned non-2xx, or DNS broke.
- **API round-trip (`/list`)** — API Gateway → Lambda failed, or the seeded Cognito JWT in the Kuma monitor expired.
- **ntfy (`/v1/health`)** — the monitoring ALB or the ntfy ECS task is down. *If this is the only thing failing, the alert that delivered it came in via Pushover; ntfy push will be missing.*

## Who/what is impacted

| Probe | User impact |
| --- | --- |
| 993 (IMAP) | Mail clients can't read mail. |
| 25 (SMTP relay) | Inbound mail bounces or queues remotely. |
| 587 / 465 (Submission) | Mail clients can't send. |
| Admin app | The browser admin client is unreachable. Mail itself unaffected. |
| `/list` | Address management is broken. Mail itself unaffected. |
| ntfy | The push channel for warnings is broken. Pushover still works for critical. |

## First three things to check

The label `instance` (Prometheus) or the monitor name (Kuma) tells you which probe. Then:

1. **Is the symptom external or internal?** Test from outside AWS:
   ```sh
   nc -zv imap.<control-domain> 993        # mail ports
   curl -I https://admin.<control-domain>/ # admin app
   curl -I https://ntfy.<control-domain>/v1/health
   ```
   Compare with `aws ecs execute-command` into a task in the same VPC. If the in-VPC test passes and the public test fails, the issue is at the load balancer or DNS layer. If both fail, the issue is in the service itself.
2. **Is the ECS service healthy?**
   ```sh
   aws ecs describe-services --cluster <cluster> --services cabal-imap cabal-smtp-in cabal-smtp-out cabal-uptime-kuma cabal-ntfy --query 'services[].{name:serviceName,running:runningCount,desired:desiredCount,events:events[0:3]}'
   ```
   `runningCount < desiredCount` for the relevant service is the smoking gun. The recent `events[]` usually identifies the cause (image pull failure, EFS access point error, capacity).
3. **Is the load balancer routing correctly?** For mail probes, check the NLB target group health for the failing port. For HTTP probes, check the monitoring ALB target group (`cabal-uptime-kuma`, `cabal-ntfy`, etc.). Healthy targets + a failing public probe means a security-group rule, listener rule, or DNS issue, not the service.

## Escalation

If all three checks pass but the probe stays red:
- For `/list` specifically, the most common cause is the seeded JWT having expired — re-seed it (see [docs/monitoring.md §9](../../monitoring.md#9-create-the-phase-1-monitor-set)) before assuming the API is broken.
- For mail ports, examine fail2ban activity: `aws logs tail /ecs/cabal-imap --filter-pattern fail2ban | head -100`. A blanket ban can drop the probe source if Kuma's outbound IP shifted.
- If a single ECS service is stuck restarting, scale it to 0 then back to 1 to break the loop (`aws ecs update-service --cluster <cluster> --service <name> --desired-count 0`, wait, then back to 1).
- If multiple services are unhealthy at once, look at the cluster instances (`aws ecs list-container-instances`) — likely an EC2 host is wedged. NAT instance failures also break outbound for any service that calls AWS APIs at start.

# Runbook: LambdaErrors

Fired by Prometheus rule [`LambdaErrors`](../../../docker/prometheus/rules/alerts.yml) — one or more invocation errors on a `cabal-*` function in the last 15 min.

## What this means

A Lambda function raised an unhandled exception (or otherwise returned an error response that AWS counted as `Errors`). This is a strict superset of the API-fronted errors that [`Lambda5xxSpike`](./lambda-5xx-spike.md) catches: it also covers the `cognito-counter` post-confirmation trigger, the `certbot-renewal` Lambda, the DMARC processing Lambda, and the `backup_heartbeat` Lambda.

## Who/what is impacted

| Function | Impact of an error |
| --- | --- |
| `cabal-list`, `cabal-fetch-message`, etc. | API request fails. See [`Lambda5xxSpike`](./lambda-5xx-spike.md). |
| `cabal-cognito-counter` | New user post-confirmation step didn't run — user account exists but isn't fully provisioned. |
| `cabal-certbot-renewal` | Mail-tier Let's Encrypt renewal stalled. The [heartbeat](./heartbeat-certbot-renewal.md) will eventually fire too. |
| `cabal-process-dmarc` | DMARC reports aren't being filed; affects long-term auth visibility, not deliverability. |
| `cabal-backup-heartbeat` | Phase 2 backup heartbeat path is broken; the backup itself may still be fine. |
| `cabal-alert-sink` | An alert was *received* but couldn't fan out. Critical — means the next page might not arrive. Check Pushover/ntfy/SSM secret state immediately. |

## First three things to check

1. **Which function?** The `function_name` label answers this. Get the last error:
   ```sh
   aws logs tail /aws/lambda/<function-name> --since 30m --filter-pattern '?ERROR ?Exception ?Traceback' | head -50
   ```
2. **Is it a deploy or runtime issue?** Cross-reference recent Lambda deploys (`lambda_api_python.yml` workflow runs on the relevant branch). A first-error-after-deploy is a regression; an error after weeks of stability points to upstream (DDB, IMAP, Cognito) or data-shape (a malformed request).
3. **Is it user-visible?** For API Lambdas this overlaps `Lambda5xxSpike` and a critical may already be queued — confirm in Alertmanager. For non-API Lambdas (counter / certbot / dmarc / heartbeat) the user impact is delayed — the related heartbeat or feature works until the next scheduled run.

## Escalation

- This rule is `warning` severity, deliberately. If errors persist past 30 min on a user-visible Lambda, expect a `critical` follow-up via `Lambda5xxSpike`.
- For `cabal-alert-sink` failures: the next page will silently fail. Investigate immediately. Check the SSM Pushover/ntfy secrets and the Lambda's CloudWatch log group for the actual transport error (`pushover status N` or `ntfy status N`).

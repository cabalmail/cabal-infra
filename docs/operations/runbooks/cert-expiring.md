# Runbook: certificate expiring soon

Fired by:
- Prometheus rules [`BlackboxTLSCertExpiringSoonWarning`](../../../docker/prometheus/rules/alerts.yml) (<21 days) and `BlackboxTLSCertExpiringSoonCritical` (<7 days) — sourced from `probe_ssl_earliest_cert_expiry` on the live TLS handshake against each endpoint the `blackbox-tls` scrape job targets.
- Kuma "Control-domain cert" monitor (Keyword type, certificate-expiry notification at 21 / 7 / 1 days).

The alert's `instance` label identifies which endpoint is expiring. Two distinct certs live behind two distinct endpoints:

| `instance` | Cert | Termination point | Renewal path |
| --- | --- | --- | --- |
| `imap.<control-domain>:993` | ACM `*.<control-domain>` (wildcard) | NLB | AWS auto-renewal (DNS validation) |
| `smtp-out.<control-domain>:465` | Let's Encrypt (per-host) | smtp-out container | `cabal-certbot-renewal` Lambda |

(There used to be a parallel pair of `CertExpiringSoon{Warning,Critical}` rules sourced from `aws_certificatemanager_days_to_expiry_minimum`. cloudwatch_exporter v0.16.0 silently dropped that metric under every configuration we tried; the blackbox path measures the same cert from a more honest place — what's actually on the wire — so the CloudWatch source was removed. The runbook below covers both renewal pipelines because either alert can fire from a different cause.)

## What this means

The TLS certificate serving `{{ $labels.instance }}` is approaching expiry. ACM normally auto-renews around T-30; the certbot Lambda runs daily and renews when remaining days drop below a configured threshold. <21 days remaining on either source means that pipeline is stuck.

## Who/what is impacted

When a cert actually expires:
- **ACM wildcard (`:993` and everything else fronted by the wildcard)** — admin app (CloudFront), API Gateway, monitoring ALB (Kuma, ntfy, Healthchecks, Grafana), IMAP listener on the NLB. Mail-domain entries in `TF_VAR_MAIL_DOMAINS` have no certs by design (they are address namespaces only) — only the control domain has one.
- **Let's Encrypt cert (`:465`/`:587`)** — SMTP submission to smtp-out fails TLS handshake. Outbound delivery via port 25 to peer MXes continues since most peers don't validate, but customer-side submission stops.

## First three things to check

Which pipeline depends on which endpoint the alert names.

### If `instance` ends in `:993` (ACM cert)

1. **Why has ACM not renewed?** ACM uses DNS validation. If the validation CNAME records were deleted from Route 53 or the wildcard's domain validation went stale, renewal halts:
   ```sh
   aws acm describe-certificate --certificate-arn <arn> \
     --query 'Certificate.{status:Status,renewalStatus:RenewalSummary.RenewalStatus,reason:RenewalSummary.RenewalStatusReason,validations:RenewalSummary.DomainValidationOptions}'
   ```
   `RenewalStatusReason` usually identifies the issue (`DOMAIN_NOT_ALLOWED_BY_CAA`, `DOMAIN_VALIDATION_DENIED`, missing CNAME, etc.).
2. **Are the validation CNAMEs still in Route 53?** Compare `_<random>.<control-domain>` records in the public hosted zone against the `ResourceRecord` entries from step 1. Re-add any that are missing.
3. **Is the live endpoint actually serving the cert ACM thinks is current?** Compare the NLB listener's certificate ARN against the ACM `Certificate.Arn`. A mismatch means the listener is pinned to an old ARN.

### If `instance` ends in `:465` or `:587` (Let's Encrypt cert)

1. **When did `cabal-certbot-renewal` last run?** Check the Lambda's last invocation and any errors:
   ```sh
   aws lambda invoke --function-name cabal-certbot-renewal /tmp/out.json && cat /tmp/out.json
   aws logs tail /aws/lambda/cabal-certbot-renewal --since 7d
   ```
   The Lambda is scheduled and also can be invoked manually to force a renewal attempt.
2. **Did the renewed cert reach the smtp-out container?** The container loads its cert from SSM/EFS via the entrypoint shim at task start. If the cert was rotated but the smtp-out task wasn't restarted, it still serves the old one:
   ```sh
   aws ecs update-service --cluster cabal-mail --service cabal-smtp-out --force-new-deployment
   ```
3. **Is Let's Encrypt rate-limiting the account?** Repeated failed renewals will eventually hit the per-domain weekly rate limit (currently 5/week). Check the Lambda logs for `429` or `rateLimited` responses; if hit, wait until the window clears before re-running.

## Escalation

If ACM renewal is stuck and the cert has <14 days remaining:
- Re-request the cert: `aws acm request-certificate --domain-name '*.<control-domain>' --validation-method DNS`. This issues a new ARN; you'll need to update everywhere it's referenced (CloudFront, ALB listeners, NLB listener). Don't do this lightly — it's destructive to live traffic during the cutover.
- If only some probes complain, the affected listener may be pinned to an old ARN — re-apply the relevant Terraform module.

If the Let's Encrypt renewal is stuck and the cert has <7 days remaining:
- Manual renewal via `certbot certonly --manual` from a workstation with the validation TXT records published, then upload the resulting PEM bundle to wherever `cabal-certbot-renewal` writes its output (SSM Parameter Store under `/cabal/letsencrypt/*`), then force a smtp-out redeploy.

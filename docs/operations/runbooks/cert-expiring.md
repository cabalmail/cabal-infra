# Runbook: certificate expiring soon

Fired by:
- Prometheus rules [`CertExpiringSoonWarning`](../../../docker/prometheus/rules/alerts.yml) (<21 days) and `CertExpiringSoonCritical` (<7 days) — sourced from `aws_certificatemanager_days_to_expiry_minimum`.
- Prometheus rule `BlackboxTLSCertExpiringSoon` (<21 days) — sourced from the live TLS handshake against `https://admin.<control-domain>/`.
- Kuma "Control-domain cert" monitor (Keyword type, certificate-expiry notification at 21 / 7 / 1 days).

## What this means

The TLS certificate for `*.<control-domain>` (the only ACM cert Cabalmail uses) is approaching its expiry. ACM normally auto-renews around T-30; <21 days remaining means auto-renewal is stuck. Mail-domain entries in `TF_VAR_MAIL_DOMAINS` have no certs by design (they are address namespaces only) — only the control domain has one.

## Who/what is impacted

When the cert actually expires, every public TLS endpoint fronted by the wildcard breaks at once: admin app (CloudFront), API Gateway, monitoring ALB (Kuma, ntfy, Healthchecks, Grafana), and IMAP/Submission listeners that load the cert via the entrypoint shim. SMTP relay on port 25 to MX continues since most peers don't validate, but submission and IMAP fail hard.

## First three things to check

1. **Why has ACM not renewed?** ACM uses DNS validation. If the validation CNAME records were deleted from Route 53 or the wildcard's domain validation went stale, renewal halts:
   ```sh
   aws acm describe-certificate --certificate-arn <arn> \
     --query 'Certificate.{status:Status,renewalStatus:RenewalSummary.RenewalStatus,reason:RenewalSummary.RenewalStatusReason,validations:RenewalSummary.DomainValidationOptions}'
   ```
   `RenewalStatusReason` usually identifies the issue ("DOMAIN_NOT_ALLOWED_BY_CAA", "DOMAIN_VALIDATION_DENIED", missing CNAME, etc.).
2. **Are the validation CNAMEs still in Route 53?** Compare `_<random>.<control-domain>` records in the public hosted zone against the `ResourceRecord` entries from step 1. Re-add any that are missing.
3. **Is `certbot-renewal` (the unrelated Lambda) confused with this?** No — that Lambda renews Let's Encrypt certs that the **mail tiers** use locally. The control-domain cert is ACM-managed and AWS handles its renewal. Don't waste time invoking the certbot Lambda for a missing ACM renewal.

## Escalation

If renewal is stuck and the cert has <14 days remaining:
- Re-request the cert: `aws acm request-certificate --domain-name '*.<control-domain>' --validation-method DNS`. This issues a new ARN; you'll need to update everywhere it's referenced (CloudFront, ALB listeners). Don't do this lightly — it's destructive to live traffic during the cutover.
- The blackbox and Kuma probes should agree with the AWS-side metric. If `aws_certificatemanager_days_to_expiry_minimum` says fine but blackbox says expiring, the live handshake is using a different cert than ACM thinks is current. Check CloudFront/ALB listener cert ARNs against the ACM `Certificate.Arn`.
- If only the monitoring-ALB probes complain (not admin.<control-domain>), the ALB listener may be pinned to an old ARN — re-apply the monitoring module.

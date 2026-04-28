# Runbook: heartbeat missed — `certbot-renewal`

Fired by Healthchecks when the `certbot-renewal` check has been silent past its grace window (24 h beyond the 60-day expected cadence).

## What this means

The `cabal-certbot-renewal` Lambda did not ping its Healthchecks URL on its last scheduled run. It may have:
- Failed to invoke at all (EventBridge schedule disabled or stale).
- Invoked and crashed before reaching the ping.
- Invoked, succeeded, but couldn't reach Healthchecks (network or token issue).

The Lambda is the source of Let's Encrypt certs **for the mail tiers** (Sendmail/Dovecot inside the IMAP and SMTP-OUT containers). It is unrelated to ACM, which auto-renews the control-domain wildcard separately. See [cert-expiring.md](./cert-expiring.md) for the ACM cert.

## Who/what is impacted

Mail-tier TLS certs expire on a 90-day Let's Encrypt cycle. The Lambda runs every 60 days, leaving 30 days of buffer. One missed run drops to ~30 days of buffer; two missed runs lets certs actually expire — at which point IMAP TLS, Submission TLS, and STARTTLS all break for users. Inbound SMTP relay still works since most peers don't validate.

## First three things to check

1. **Did the Lambda invoke at all?**
   ```sh
   aws logs describe-log-streams --log-group-name /aws/lambda/cabal-certbot-renewal \
     --order-by LastEventTime --descending --max-items 5 \
     --query 'logStreams[].{stream:logStreamName,last:lastEventTimestamp}'
   ```
   If the most-recent log stream is days/weeks old, EventBridge isn't firing. Check the schedule:
   ```sh
   aws scheduler list-schedules --name-prefix cabal-certbot
   ```
2. **Did it invoke and crash?** Pull the latest invocation:
   ```sh
   aws logs tail /aws/lambda/cabal-certbot-renewal --since 7d | tail -200
   ```
   Common crashes: ACME authorization timeout (DNS-01 challenge stuck), SSM parameter for the account key missing, failure pushing the renewed cert to S3.
3. **Did it succeed but fail to ping?**
   ```sh
   aws ssm get-parameter --name /cabal/healthcheck_ping_certbot_renewal --with-decryption --query Parameter.Value --output text
   ```
   If the value is `placeholder-` or doesn't start with `http`, the ping is intentionally suppressed (which means the alert is false-positive — make sure the SSM value is a real Healthchecks ping URL once the corresponding check is enabled in [docs/monitoring.md §12](../../monitoring.md#12-create-one-check-per-scheduled-job)).

## Escalation

- **Force a renewal now**: `aws lambda invoke --function-name cabal-certbot-renewal /tmp/out.json && cat /tmp/out.json`. This both renews and pings; the Healthchecks check should turn green within a minute (after Lambda cold-start).
- **Schedule disabled in Terraform**: re-enable in the `certbot_renewal` module.
- **Account key issue**: the ACME account is a one-time bootstrap (see [docs/setup.md](../../setup.md)). If lost, generate a new key and re-register.
- This alert is `critical`. The buffer between heartbeat-missed and actual cert expiry is 30+ days, so don't panic-page yourself out of bed for a 2 AM alert; address it the next business day. But don't *ignore* it for a week.

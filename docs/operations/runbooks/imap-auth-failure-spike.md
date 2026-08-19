# Runbook: IMAPAuthFailureSpike

Fired by Prometheus rule [`IMAPAuthFailureSpike`](../../../docker/prometheus/rules/alerts.yml) — more than 25 Dovecot "auth failed" log lines on the imap tier in the last 5 minutes, sustained for 5 minutes.

## What this means

Dovecot's IMAP login process rejected credentials at a sustained rate of >5/min. The alert counts log lines matching `"imap-login" "auth failed"` ([`log_metrics.tf`](../../../terraform/infra/modules/monitoring/log_metrics.tf)), i.e. attempts that reached the authentication stage and were refused.

**It is not an internet-facing brute force, because there is nothing on the internet to brute-force.** The imap tier serves 143 only, reachable only from inside the VPC:

- The NLB carries a single listener, TCP/25; its IMAPS listener was removed in #778.
- The task ENI's security group, `cabal-ecs-imap-sg`, admits tcp/25 and tcp/143 from the VPC CIDR and nothing else.
- Since #779 the image switches Dovecot's own 993 listener off ([`99-no-imaps.conf`](../../../docker/imap/configs/dovecot/99-no-imaps.conf)) and the task definition no longer maps the port.

So a sustained firing is one of two things:

1. **The API Lambdas are failing to authenticate.** Every mailbox operation logs in as `<user>*admin` with the master password from SSM `/cabal/master_password` ([`_shared/helper.py`](../../../lambda/api/_shared/helper.py)). A master-password rotation applied to only one side, or a Cognito user with no matching OS account (see [`sync-users.sh`](../../../docker/shared/sync-users.sh)), produces exactly this signal: a high, *uniform* failure rate that starts abruptly. This is a client-surface outage, not a security event, and it is the likely cause.
2. **Something in-VPC is guessing credentials.** A source inside `10.64.0.0/16` that is neither a Lambda ENI nor the tier's own health probe is an incident of a *different shape and severity* than the one this runbook used to describe: something already inside the private network is attempting logins. Escalate as a compromise investigation, not as an edge-filtering problem.

The reflex this runbook used to prescribe — block the source IP at the edge with a security-group or NACL rule on 993 — is the wrong first move for both, and the port it named no longer exists here.

### What will *not* fire this alert

Since #779 the tier sets `ssl = required` with `login_trusted_networks = 127.0.0.1`, and `disable_plaintext_auth = yes` ([`10-auth.conf`](../../../docker/imap/configs/dovecot/10-auth.conf)), so a LOGIN issued before STARTTLS is refused *before* any credential is checked. Those sessions log `Plaintext authentication disallowed on non-secure (SSL/TLS) connections` and aborted-login lines, not `auth failed` — so a consumer that regressed to a plaintext dial locks itself out while this alert stays **quiet**. If clients are failing and this alert has not fired, check the login log directly (first-check command 3 below) rather than concluding auth is healthy.

### Unreachable, not absent

Two security groups, `cabal-ecs-instance-sg` and `cabal-nat-instance-sg`, allow *all protocols* from `10.64.0.0/16`, so 993 is nominally open to those groups, and the container image still ships a Dovecot config that mentions the port. Neither matters: the mail tiers run in `awsvpc` mode, so the **task ENI's** security group governs, and that one stops at 25+143. Read any SG sweep or task-definition review with that in mind before concluding the port is exposed — or that some other control is what closed it.

## Who/what is impacted

- **If cause 1** — every client is locked out (the admin app, both Apple clients, the Android client), because they all reach the mailbox through the same Lambdas. Treat as critical regardless of this alert's `warning` severity.
- **If cause 2** — no direct user impact from the failed logins themselves. The impact is whatever the source is doing, and the failures are the least of it.

Login latency under load is not a meaningful concern here: `auth_failure_delay = 2 secs` and the per-service `process_limit`/`client_limit` caps in [`20-imap.conf`](../../../docker/imap/configs/dovecot/20-imap.conf) — both shipped in 0.10.x phase 4, replacing the fail2ban that was removed then — bound how fast any one source can retry.

## First three things to check

1. **Where is it coming from, and is that address a Lambda?**
   ```sh
   aws logs tail /ecs/cabal-imap --since 10m --filter-pattern '"auth failed"' \
     | grep -oE 'rip=[0-9.]+' | sort | uniq -c | sort -rn | head
   # Identify each source ENI - a Lambda's VPC ENI has InterfaceType "lambda":
   aws ec2 describe-network-interfaces \
     --filters Name=addresses.private-ip-address,Values=<rip> \
     --query 'NetworkInterfaces[].{type:InterfaceType,desc:Description,sg:Groups[].GroupName}'
   ```
   All sources are Lambda ENIs → cause 1. Any source that is not → cause 2, and identify what it is before doing anything else.
2. **Is it every user, or one?**
   ```sh
   aws logs tail /ecs/cabal-imap --since 10m --filter-pattern '"auth failed"' \
     | grep -oE 'user=<[^>]+>' | sort | uniq -c | sort -rn | head
   ```
   Every active user failing uniformly → the master credential (cause 1). One user → that user's OS account is probably missing; check the sync ran on the last task start (`--filter-pattern '"[sync-users]"'`).
3. **Are any logins succeeding, and is anything being refused before auth?**
   ```sh
   aws logs tail /ecs/cabal-imap --since 10m --filter-pattern '"imap-login: Login"' | head -20
   aws logs tail /ecs/cabal-imap --since 10m --filter-pattern '"Plaintext authentication"'
   ```
   Successes interleaved with the failures, from a source that is *not* a Lambda ENI → cause 2, and treat as critical. Plaintext-refusal lines → a consumer regressed off the STARTTLS path; that is a separate fault from this alert (see above), fixed in the consumer.

## Escalation

- **Cause 1 — the master credential or the user sync**: confirm SSM `/cabal/master_password` matches what Dovecot's master userdb was built with; a rotation has to be applied to both sides. Then confirm the running task ran `sync-users.sh` at start. Rolling the service re-runs the entrypoint end to end, which is the blunt fix once the parameter is right.
- **Cause 2 — an unexpected in-VPC source**: the control surface is the task ENI security group, not a public NACL. Narrowing `cabal-ecs-imap-sg`'s 143 ingress from the whole VPC CIDR to the private subnets the Lambdas run in cuts off any other in-VPC source without touching the legitimate path:
  ```sh
  aws ec2 revoke-security-group-ingress --group-id <cabal-ecs-imap-sg> \
    --protocol tcp --port 143 --cidr 10.64.0.0/16
  aws ec2 authorize-security-group-ingress --group-id <cabal-ecs-imap-sg> \
    --protocol tcp --port 143 --cidr <lambda-subnet-cidr>
  ```
  An emergency measure only: the next Terraform apply reverts a console edit, so follow it with the change in [`modules/ecs/security_group.tf`](../../../terraform/infra/modules/ecs/security_group.tf). Then investigate the source itself — an ECS task, an EC2 instance, or something that should not be running at all.
- **Do not widen `login_trusted_networks` or relax `ssl = required`** to make a failing client work. That allowance is what #779 closed deliberately ([entrypoint step 3](../../../docker/shared/entrypoint.sh)); the Lambdas' path is `IMAP_INTERNAL_HOST` → 143 → STARTTLS → LOGIN ([`imap_session.py`](../../../lambda/api/_shared/imap_session.py)), and anything else is a regression to fix in the consumer.
- **An account is compromised**: rotate that user's password via Cognito and invalidate active sessions. With no public listener, using the credential against IMAP also requires a foothold inside the VPC — find that first.
- This alert is `warning` because the historical case (background internet noise) was benign. That case no longer exists, so a sustained firing now means something is actually wrong. Promote it in your head to critical the moment check 1 shows a non-Lambda source, or check 2 shows every user failing.

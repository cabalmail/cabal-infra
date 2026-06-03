# Runbook: IMAPAuthFailureSpike

Fired by Prometheus rule [`IMAPAuthFailureSpike`](../../../docker/prometheus/rules/alerts.yml) — more than 25 Dovecot "auth failed" log lines on the imap tier in the last 5 minutes, sustained for 5 minutes.

## What this means

Dovecot's IMAP login process logged failed authentication attempts at a sustained rate of >5/min. The most common cause is a brute-force or credential-stuffing attempt against the public IMAP listener (port 993). Real users typing the wrong password rarely produce this volume.

## Who/what is impacted

Failed auth attempts don't directly affect anyone — Dovecot rejects them and the attacker moves on. The risks are:
- Real users may experience login latency under heavy attack load (Dovecot's bcrypt verification is intentionally slow).
- A determined attacker with a valid password gets in once they hit the right user. Cabalmail uses Cognito-issued passwords; check whether any account has a weak password set out-of-band.
- **No host-level auto-banning.** fail2ban was removed from the mail-tier images in 0.10.x (it had been commented out of [supervisord.conf](../../../docker/imap/supervisord.conf) since 0.7.x and never actually ran). Attempts are not banned at the host level. The replacement is Dovecot's own login throttling (`auth_failure_delay` plus per-service `process_limit`/`client_limit`), which lands in phase 4 of [docs/0.10.x/container-runtime-hardening-plan.md](../../0.10.x/container-runtime-hardening-plan.md); until it ships, this alert is the only signal.

## First three things to check

1. **Where is it coming from?**
   ```sh
   aws logs tail /ecs/cabal-imap --since 10m --filter-pattern '"auth failed"' \
     | grep -oE 'rip=[0-9.]+' | sort | uniq -c | sort -rn | head
   ```
   A small number of source IPs producing the bulk of attempts is a brute-force; many distinct IPs is a credential-stuffing campaign (harder to mitigate at the network layer).
2. **Is one user being targeted, or is it a username spray?**
   ```sh
   aws logs tail /ecs/cabal-imap --since 10m --filter-pattern '"auth failed"' \
     | grep -oE 'user=<[^>]+>' | sort | uniq -c | sort -rn | head
   ```
   One user in particular → escalate that user's password rotation and check whether their address is exposed publicly. Many users → spray.
3. **Are any attempts succeeding right now?** Dovecot logs successful logins as `imap-login: Login`:
   ```sh
   aws logs tail /ecs/cabal-imap --since 10m --filter-pattern '"imap-login: Login"' | head -20
   ```
   Successful logins from the same IP-range as the failures = compromise. Treat as critical even though this alert is `warning`.

## Escalation

- **Single noisy IP / small set**: block at the security group on the NLB-fronted listener. Ad-hoc:
  ```sh
  aws ec2 authorize-security-group-ingress --group-id <imap-listener-sg> --protocol tcp --port 993 --cidr 0.0.0.0/0  # already there
  # SGs don't allow deny rules; use NACLs instead, on the public subnet:
  aws ec2 create-network-acl-entry --network-acl-id <nacl> --rule-number 90 --protocol tcp --port-range From=993,To=993 --cidr-block <bad-ip>/32 --rule-action deny
  ```
- **Tighten login throttling (long-term answer)**: fail2ban is gone for good (removed in 0.10.x); the host-network model makes per-container packet inspection the wrong layer. The replacement is two-fold: Dovecot's own login-throttling knobs (`auth_failure_delay`, per-service `process_limit`/`client_limit`), landing in phase 4 of [docs/0.10.x/container-runtime-hardening-plan.md](../../0.10.x/container-runtime-hardening-plan.md); and, if attack volume warrants it, an NLB-side rate limit or WAF (tracked in the identity/IAM hardening plan). Neither bans at the iptables layer.
- **Credential stuffing across many IPs**: blocking IPs is futile. The right response is to rate-limit at the listener (Dovecot's `auth_cache_negative_ttl` and `imap_login_processes_count_throttle` settings) and to check user passwords for re-use against known-leaked lists.
- **An account is compromised**: rotate that user's password immediately via Cognito, invalidate active sessions, and ECS-Exec into the IMAP container to drop any existing IMAP connection from the attacker IP.
- This alert is `warning` because most spikes are background noise. Promote to critical (manually, in your head) if any of the third-check signals come back positive.

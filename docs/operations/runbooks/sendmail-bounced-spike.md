# Runbook: SendmailBouncedSpike

Fired by Prometheus rule [`SendmailBouncedSpike`](../../../docker/prometheus/rules/alerts.yml) — more than 15 sendmail "dsn=5" log lines aggregated across all three mail tiers in the last 30 minutes, sustained for 15 minutes.

## What this means

The pattern matches any 5.x.y DSN code — sendmail's permanent-failure (bounce) class. Permanent failures are returned to the sender as bounce messages and are usually a symptom of a real problem, not transient network noise.

## Who/what is impacted

Like [`SendmailDeferredSpike`](./sendmail-deferred-spike.md), this metric is summed across log groups and the impact depends heavily on which tier:

- **`smtp-out`**: outbound mail is being permanently rejected by remote MXs. Common causes: SPF/DKIM/DMARC misalignment, IP listed on a blocklist, sender reputation issues. **This is the most user-visible failure mode** — recipients aren't getting our mail.
- **`smtp-in`**: incoming mail to a Cabalmail-hosted address is being rejected (recipient unknown, mailbox unavailable). User-visible to *senders*; shows up as bounces in their inbox. Usually a stale `cabal-addresses` map after a recent revoke.
- **`imap`**: local delivery to a Maildir failed permanently (rare — usually a misconfigured procmail rule or a missing OS user).

## First three things to check

1. **Which tier?**
   ```sh
   for tier in imap smtp-in smtp-out; do
     echo "=== $tier ==="
     aws logs tail /ecs/cabal-$tier --since 30m --filter-pattern '"dsn=5"' | wc -l
   done
   ```
   The tier with the largest count is the offender. Look at recent 5.x.y codes for that tier:
   ```sh
   aws logs tail /ecs/cabal-<tier> --since 30m --filter-pattern '"dsn=5"' | grep -oE 'dsn=5\.[0-9]+\.[0-9]+ [^,]*' | sort | uniq -c | sort -rn | head
   ```
2. **For smtp-out (deliverability)**: confirm the bounces aren't all targeting one provider:
   ```sh
   aws logs tail /ecs/cabal-smtp-out --since 30m --filter-pattern '"dsn=5"' | grep -oE 'to=<[^@]*@[^>]*>' | awk -F'@' '{print $2}' | sort | uniq -c | sort -rn | head
   ```
   One provider dominating → that provider blocked us. Many providers → a global reputation issue. Check our DKIM is signing correctly and DMARC reports for the affected period (DMARC reports come into the dmarc inbox).
3. **For smtp-in (recipient unknown)**: check the address map is fresh:
   ```sh
   TASK=$(aws ecs list-tasks --cluster <cluster> --service-name cabal-smtp-in --query 'taskArns[0]' --output text)
   aws ecs execute-command --cluster <cluster> --task "$TASK" --container smtp-in --interactive \
     --command "/bin/sh -c 'wc -l /etc/mail/virtusertable && date -r /etc/mail/virtusertable'"
   ```
   If the file is hours old, the reconfigure loop is stuck — see [heartbeat-ecs-reconfigure.md](./heartbeat-ecs-reconfigure.md).

## Escalation

- **Deliverability issue (smtp-out)**:
  - Verify SPF, DKIM, DMARC at <https://www.mail-tester.com> from a Cabalmail address.
  - Check IP reputation: <https://mxtoolbox.com/blacklists.aspx> with the smtp-out NAT public IP and the apex of mail domains.
  - If we're recently delisted, expect a 24-48h rebuild period. Don't rotate the NAT IP — that resets reputation harder than it helps.
- **Recipient-unknown spike on smtp-in**:
  - Force a reconfigure: `aws ecs update-service --cluster <cluster> --service cabal-smtp-in --force-new-deployment`.
  - Check `cabal-addresses` table to confirm the addresses being bounced should still exist.
- **Local-delivery failure on imap**:
  - Confirm the OS user exists on the IMAP container (the reconfigure loop syncs from Cognito).
  - Confirm `/home/<user>/Maildir` exists and is writable by the user's UID.
- This is **critical**. Sustained outbound bounces hurt reputation cumulatively; resolve same-day. Sustained inbound bounces send "mailbox doesn't exist" messages back to senders, which damages user trust quickly.

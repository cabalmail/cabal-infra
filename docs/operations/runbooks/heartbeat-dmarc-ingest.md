# Runbook: heartbeat missed — `dmarc-ingest`

Fired by Healthchecks when the `dmarc-ingest` check has been silent past its 2-hour grace beyond the 6-hour expected cadence.

## What this means

The `cabal-process-dmarc` Lambda did not ping in its last scheduled run. The Lambda receives DMARC aggregate-report mail at the `dmarc-reports@mail-admin.<first-mail-domain>` address (via `lambda/api/process_dmarc/`) and writes the parsed reports to S3.

## Who/what is impacted

DMARC aggregate-reports are **diagnostic**, not control-plane. Missing them does not affect mail deliverability — it only affects our ability to see how downstream mailbox providers are evaluating our SPF/DKIM/DMARC over time.

So: this alert never warrants a wake-up. It's a `critical` severity in Phase 2 because Healthchecks doesn't have per-check severity overrides, but operationally it's "look at it during business hours". Phase 4 §3 IaC config can fix this with per-check severity once Healthchecks config is code.

## First three things to check

1. **Did the Lambda invoke at all?**
   ```sh
   aws logs describe-log-streams --log-group-name /aws/lambda/cabal-process-dmarc \
     --order-by LastEventTime --descending --max-items 5
   ```
2. **What's the inbound queue look like?** The Lambda is invoked off SES inbound rules / S3 events. If no DMARC reports have arrived recently (provider-side issue or our mail to the dmarc address has been bouncing), the Lambda has nothing to do — and won't ping.
   ```sh
   aws s3 ls s3://<bucket>/dmarc-reports/ --recursive --summarize | tail -5
   ```
   Confirm by checking your inbox for `dmarc-reports@mail-admin.<first-mail-domain>` — if reports are arriving, Lambda invocation is the issue.
3. **Did the Lambda crash?**
   ```sh
   aws logs tail /aws/lambda/cabal-process-dmarc --since 24h --filter-pattern '?ERROR ?Exception ?Traceback'
   ```

## Escalation

- **No DMARC reports arriving** is the most common cause and is benign. Confirm by checking that recent outbound mail from a Cabalmail address arrived at gmail.com / outlook.com (those providers send daily aggregates).
- **Lambda crashing**: most likely a malformed report (gzip parse error, non-XML payload). The Lambda should swallow these and continue; if it's hard-failing, fix and redeploy.
- **Healthchecks ping URL missing or wrong**: see [docs/monitoring.md §12](../../monitoring.md#12-create-one-check-per-scheduled-job). Re-seed `/cabal/healthcheck_ping_dmarc_ingest`.

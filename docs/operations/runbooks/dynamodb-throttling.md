# Runbook: DynamoDBThrottling

Fired by Prometheus rule [`DynamoDBThrottling`](../../../docker/prometheus/rules/alerts.yml) — any `ThrottledRequests` on a Cabalmail-owned table in the last 5 min.

## What this means

DynamoDB rejected one or more requests because the table or a partition exceeded its capacity. Cabalmail uses on-demand mode for `cabal-addresses`, so this is rare — it usually means the table just experienced a 2× burst beyond its tracked baseline (DynamoDB on-demand absorbs only up to that double) or a hot-partition read pattern.

## Who/what is impacted

The label `table_name` identifies the table.

- `cabal-addresses`: address-creation, address-revocation, sendmail virtusertable regeneration, IMAP user→inbox lookup. Throttling here translates directly into 5xx on `cabal-list` / `cabal-new` / `cabal-revoke` and missed deliveries during the throttle window.
- Any other Cabalmail table: investigate as a regression — the codebase doesn't currently create others.

## First three things to check

1. **Burst or hot partition?**
   ```sh
   aws cloudwatch get-metric-statistics --namespace AWS/DynamoDB --metric-name ConsumedReadCapacityUnits \
     --dimensions Name=TableName,Value=<table> \
     --start-time $(date -u -v-1H +%FT%TZ) --end-time $(date -u +%FT%TZ) \
     --period 60 --statistics Sum,Maximum
   ```
   A clean spike pattern is a burst (transient — ride it out). A flat baseline with throttling means a hot partition (one key getting hammered).
2. **What's the access pattern right now?**
   ```sh
   aws logs tail /aws/lambda/cabal-list --since 15m | head -100
   ```
   Check whether one user/email is dominating reads. The `ecs-reconfigure` loop also scans the table — confirm it's not stuck in a tight loop (see [heartbeat-ecs-reconfigure.md](./heartbeat-ecs-reconfigure.md)).
3. **Did Terraform recently switch the table from on-demand to provisioned?** Mode changes silently cap capacity. Check `aws dynamodb describe-table --table-name <table> --query 'Table.BillingModeSummary'`.

## Escalation

- If the cause is a tight reconfigure loop, throttle it (the SQS message dispatch should be idempotent — back-off on the consumer is the right fix, not a bigger table).
- If it's a genuine load increase that's likely sustained, switch the table to provisioned + autoscaling. Note: `cabal-addresses` rarely has any sustained load — investigate unusual traffic before reconfiguring.
- This is `warning` severity. Sustained throttling typically promotes to user-visible 5xx within minutes, which `Lambda5xxSpike` will catch as critical.

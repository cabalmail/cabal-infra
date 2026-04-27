# Runbook: DynamoDBSystemErrors

Fired by Prometheus rule [`DynamoDBSystemErrors`](../../../docker/prometheus/rules/alerts.yml) — any `SystemErrors` on a Cabalmail table in the last 5 min.

## What this means

A DynamoDB request returned a 5xx that AWS classifies as their fault, not the caller's. These are not the same as throttles. They typically signal an issue inside the DynamoDB service in the region.

## Who/what is impacted

Same blast radius as [`DynamoDBThrottling`](./dynamodb-throttling.md) but worse: the application gets a hard error rather than a "retry-with-backoff". Address-list reads, address creation, virtusertable regeneration, and inbound delivery lookups all fail until DynamoDB recovers.

## First three things to check

1. **Is AWS having a DynamoDB incident?** Check <https://health.aws.amazon.com/health/status>. A regional service event usually shows up there before our metric noticeably moves. If yes, the right action is *wait* — there's no fix on our side.
2. **Is it one table, one operation, or all?** Look at the metric breakdown in Grafana. If only `BatchGetItem` errors and others are clean, it's a known DynamoDB API-specific transient. If all operations on one table are erroring, something is wrong with that table specifically.
3. **Is the application retrying correctly?** boto3's default retry config covers throttles but `SystemErrors` need their own retry policy. Check `cabal-list` log group for whether retries are happening:
   ```sh
   aws logs tail /aws/lambda/cabal-list --since 15m --filter-pattern 'ProvisionedThroughputExceededException InternalServerError'
   ```

## Escalation

- This rule is **critical** — a Pushover push goes out. Page first, dig second.
- If AWS confirms an incident, leave the alert firing until they resolve. Don't add silences for an active outage — when AWS recovers, having the alert visibly clear is a useful signal.
- If we're the only one seeing it, open an AWS support ticket with example RequestIds from the boto3 error logs. The application's retry behavior is the only thing we can change in flight; everything else is at AWS.

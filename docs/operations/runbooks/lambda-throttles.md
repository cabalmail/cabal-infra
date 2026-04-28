# Runbook: LambdaThrottles

Fired by Prometheus rule [`LambdaThrottles`](../../../docker/prometheus/rules/alerts.yml) — any throttled invocations on a `cabal-*` function in the last 5 min.

## What this means

A Lambda invocation was rejected because the function's reserved concurrency (or the account-level concurrency limit) was already saturated. Each throttled invocation is a user request that didn't run.

## Who/what is impacted

The label `function_name` identifies the function. For most `cabal-*` functions throttling shows up as failed admin-app calls (slow or 5xx). Throttling on `cognito-counter` (post-confirmation trigger) blocks new sign-ups for the duration.

## First three things to check

1. **Is this a load spike or a configuration change?** Check the function's Invocations metric for the last hour:
   ```sh
   aws cloudwatch get-metric-statistics --namespace AWS/Lambda --metric-name Invocations \
     --dimensions Name=FunctionName,Value=<fn> \
     --start-time $(date -u -v-1H +%FT%TZ) --end-time $(date -u +%FT%TZ) \
     --period 60 --statistics Sum
   ```
   A 10× spike vs baseline points to a load issue (or a runaway client). Flat baseline + throttling means concurrency was reduced.
2. **What's the function's reserved concurrency?**
   ```sh
   aws lambda get-function-concurrency --function-name <fn>
   ```
   Cabalmail Lambdas don't normally set reserved concurrency — if a value is present, somebody set it deliberately or Terraform regressed. Check the recent commit to the call module.
3. **Is the account near its concurrency limit?** Check `ConcurrentExecutions` against the account limit (default 1000):
   ```sh
   aws service-quotas get-service-quota --service-code lambda --quota-code L-B99A9384
   ```
   At <70% of limit this is the function's problem; >70% means a noisy neighbor.

## Escalation

- For an account-wide ceiling, request a quota increase via AWS Support.
- For a runaway-client load spike, identify the source IP or Cognito user from API Gateway access logs and consider WAF rate-limiting at the CloudFront layer.
- This alert is `warning` severity — ntfy only, no Pushover. If throttling is sustained for >30 min and converting to user-visible 5xx, [`Lambda5xxSpike`](./lambda-5xx-spike.md) will escalate to `critical`.

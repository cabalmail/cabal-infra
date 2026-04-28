# Runbook: Lambda5xxSpike

Fired by Prometheus rule [`Lambda5xxSpike`](../../../docker/prometheus/rules/alerts.yml) — API Gateway 5xx rate over 5% for 5 min on a `cabal-*` API.

## What this means

API Gateway returned 5xx for more than 5% of requests over a 10-minute window. The cause is almost always a Lambda function fronting the API: a new deploy with a bug, a runtime exception, an IAM permission missing on the task role, or an upstream dependency (DynamoDB / IMAP / SES) timing out.

## Who/what is impacted

The label `apiname` identifies which API. For Cabalmail there is one API (`cabal-api`) with one stage (`prod`) — every API call from the admin web app goes through it. A sustained 5xx spike means address management, message reads, sends, and folder operations are broken.

## First three things to check

1. **Which Lambda is failing?** Pull recent errors across all `cabal-*` Lambdas:
   ```sh
   for fn in $(aws lambda list-functions --query 'Functions[?starts_with(FunctionName,`cabal-`)].FunctionName' --output text); do
     count=$(aws cloudwatch get-metric-statistics --namespace AWS/Lambda --metric-name Errors --dimensions Name=FunctionName,Value=$fn --start-time $(date -u -v-15M +%FT%TZ) --end-time $(date -u +%FT%TZ) --period 60 --statistics Sum --query 'Datapoints[].Sum' --output text | tr '\t' '\n' | awk '{s+=$1} END{print s+0}')
     [ "$count" != "0" ] && echo "$fn: $count errors in last 15 min"
   done
   ```
2. **What's the error?** For the function from step 1, tail the log group for stack traces:
   ```sh
   aws logs tail /aws/lambda/<function-name> --since 15m --filter-pattern '?ERROR ?Exception ?Traceback'
   ```
3. **Is it environment-wide or one route?** Check the Grafana **API Gateway & Lambda** dashboard — if every route is failing, suspect the API Gateway authorizer, the shared `helper.py` layer, or DynamoDB. If one route, the recent change to that function's code is the prime suspect.

## Escalation

- **Recent deploy?** Roll back. The image tag is in SSM at `/cabal/deployed_image_tag`; the previous tag is in CloudWatch on the `lambda_api_python` workflow runs. Re-trigger the Terraform workflow with the older tag in SSM.
- **DynamoDB throttling correlated?** Check the [DynamoDB throttling runbook](./dynamodb-throttling.md); the cause may not be the Lambda itself.
- **IMAP backend down?** Most read-side handlers proxy to the IMAP tier. Check the [probe-failure runbook](./probe-failure.md) for IMAP first, then come back here.
- If the issue persists with no root cause, capture a request ID from CloudWatch and X-Ray (if enabled) and open a GitHub issue with the log excerpt.

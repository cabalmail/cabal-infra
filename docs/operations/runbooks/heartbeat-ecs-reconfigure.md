# Runbook: heartbeat missed — `ecs-reconfigure`

Fired by Healthchecks when the `ecs-reconfigure` check has been silent past its 30-minute grace beyond the 30-minute expected cadence.

## What this means

The `reconfigure.sh` loop in one or more mail-tier containers stopped pinging. This script regenerates sendmail maps, virtusertable, DKIM tables, and OS users from DynamoDB and Cognito; it runs continuously inside each mail-tier container, polling SQS and falling back to a 15-minute timer.

A missed ping means *at least one* mail-tier container is no longer reconciling configuration. New addresses created via the admin app may not be receiving mail; revoked addresses may still be deliverable.

## Who/what is impacted

The label embedded in the alert summary tells you *which* check was missed, but Cabalmail registers a single `ecs-reconfigure` check, so you don't know from the alert alone which of the three mail tiers (`imap`, `smtp-in`, `smtp-out`) stopped pinging — the loop runs in all three. Address-management correctness is the user-visible impact.

## First three things to check

1. **Is the reconfigure loop alive in each mail-tier task?** ECS Exec into each:
   ```sh
   for tier in imap smtp-in smtp-out; do
     echo "=== $tier ==="
     TASK=$(aws ecs list-tasks --cluster <cluster> --service-name cabal-$tier --query 'taskArns[0]' --output text)
     aws ecs execute-command --cluster <cluster> --task "$TASK" --container $tier --interactive \
       --command "/bin/sh -c 'pgrep -af reconfigure || echo no-reconfigure-process'"
   done
   ```
   If a tier shows "no-reconfigure-process", supervisord stopped restarting the loop — examine the container's supervisord log.
2. **Is the SQS queue backing up?**
   ```sh
   aws sqs get-queue-attributes --queue-url <reconfigure-queue-url> \
     --attribute-names ApproximateNumberOfMessages,ApproximateNumberOfMessagesNotVisible
   ```
   A growing visible count or stuck-invisible count means the loop is consuming but failing partway through (likely DynamoDB throttling — see [dynamodb-throttling.md](./dynamodb-throttling.md)).
3. **Are the SSM parameters consistent across tiers?** If `/cabal/healthcheck_ping_ecs_reconfigure` was rotated but only one task was force-redeployed, the others are still using the old value at task-start cache. Force-redeploy the rest:
   ```sh
   for tier in imap smtp-in smtp-out; do
     aws ecs update-service --cluster <cluster> --service cabal-$tier --force-new-deployment
   done
   ```

## Escalation

- **Loop crashed inside container**: the supervisord config restarts it, so a true crash should self-heal. If supervisord is reporting "FATAL Too many start retries", the script itself is broken — `aws logs tail /ecs/cabal-imap --since 1h --filter-pattern reconfigure`.
- **DynamoDB-related stalls**: not this runbook. Address through [dynamodb-throttling.md](./dynamodb-throttling.md) or [dynamodb-system-errors.md](./dynamodb-system-errors.md).
- **Cognito ListUsers throttling**: the loop also touches Cognito to sync OS users. Check `aws_cognito_*_throttles` in Prometheus.
- This is `critical` — address-management correctness is core functionality. Page-level urgency, but mail itself continues to flow on the previous map state.
